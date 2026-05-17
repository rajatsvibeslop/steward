//
//  MemoryRetriever.swift
//  Steward
//
//  Hybrid retrieval per spec §9 / addendum §1.5:
//
//    FTS5 BM25 prefilter (topK=40)  ∪  NLEmbedding cosine prefilter (topK=40)
//        → load full rows
//        → rerank by
//             (0.45 * cosine + 0.25 * bm25_norm + 0.20 * recency + 0.10 * typeBonus)
//             * effectiveStrength(now:)        (lazy decay)
//        → topK by score → bump last_accessed_at on the survivors
//
//  All cosine comparisons use Accelerate.vDSP.dotProduct on already-
//  normalized vectors (researcher landmine).
//

import Foundation
import GRDB

struct MemoryHit: Equatable, Sendable {
    let item: MemoryItem
    let score: Double
    let cosine: Double
    let bm25Normalized: Double
    let recency: Double
    let typeBonus: Double
    let effectiveStrength: Double
}

enum MemoryRetrieverError: Error, CustomStringConvertible, Equatable {
    case embedderUnavailable(reason: String)

    var description: String {
        switch self {
        case .embedderUnavailable(let r): return "embedder unavailable: \(r)"
        }
    }
}

/// Hybrid retrieval entry point. Returns up to `limit` ranked hits.
///
/// Designed to be safe when memory is empty (returns `[]`) and when the
/// embedder is unavailable (falls back to FTS-only ranking with cosine=0).
enum MemoryRetriever {

    /// Tunable weights — sum to 1.0 over cosine/bm25/recency/typeBonus.
    private static let cosineWeight: Double = 0.45
    private static let bm25Weight:   Double = 0.25
    private static let recencyWeight: Double = 0.20
    private static let typeBonusWeight: Double = 0.10

    /// FTS5 prefilter cap (per addendum §1.5 / spec §9).
    private static let lexicalTopK: Int = 40
    /// Vector prefilter cap.
    private static let semanticTopK: Int = 40

    static func retrieve(
        query: String,
        domain: String? = nil,
        types: [MemoryType]? = nil,
        limit: Int = 8,
        now: Date = Date(),
        in queue: DatabaseQueue,
        embedder: Embedder = .shared,
        recordRetrievalBoost: Bool = true
    ) async throws -> [MemoryHit] {

        // 2. Embedding for the query. If unavailable (model not present), we
        //    still rank by BM25 + recency + type — degraded but useful.
        var qVec: [Float]? = nil
        do {
            qVec = try await embedder.embed(query)
        } catch {
            // Surface as a debug breadcrumb only; do NOT throw. Memory must
            // remain usable when the embedder is offline.
            qVec = nil
        }
        let queryVec = qVec

        // 1 + 3 + 5: read-only steps in one `read` block so GRDB hands us a
        // consistent Database handle.
        let scoredHits: [MemoryHit] = try await queue.read { db in
            let lexical = try ftsSearch(query: query, domain: domain, types: types, in: db)

            let semanticIDs: [MemoryID] = try semanticPrefilter(
                queryVec: queryVec,
                domain: domain,
                types: types,
                topK: semanticTopK,
                in: db
            )

            // 4. Union of candidate Ids (de-duped).
            var candidateIDs = Set<MemoryID>(lexical.keys)
            for id in semanticIDs { candidateIDs.insert(id) }
            if candidateIDs.isEmpty { return [] }

            // 5. Load rows + rerank.
            let items = try MemoryItem.fetchMany(db: db, memoryIDs: Array(candidateIDs))
            let maxBM25 = lexical.values.max() ?? 0

            var hits: [MemoryHit] = []
            hits.reserveCapacity(items.count)
            for item in items {
                if item.isExpired(now: now) { continue }
                let cos: Double
                if let q = queryVec {
                    cos = Double(Embedder.cosine(q, item.embedding))
                } else {
                    cos = 0
                }
                let bm25Raw = lexical[item.memoryID] ?? 0
                let bm25Norm = maxBM25 > 0 ? (bm25Raw / maxBM25) : 0
                let recency = recencyScore(item.lastAccessedAt ?? item.createdAt, now: now)
                let typeBonus = item.type.rerankerBonus
                let lazyStrength = item.effectiveStrength(now: now)
                let raw =
                    cosineWeight * cos +
                    bm25Weight * bm25Norm +
                    recencyWeight * recency +
                    typeBonusWeight * typeBonus
                let score = raw * lazyStrength
                hits.append(MemoryHit(
                    item: item,
                    score: score,
                    cosine: cos,
                    bm25Normalized: bm25Norm,
                    recency: recency,
                    typeBonus: typeBonus,
                    effectiveStrength: lazyStrength
                ))
            }
            hits.sort { $0.score > $1.score }
            return Array(hits.prefix(limit))
        }

        // 6. Boost retrieval strength on survivors. Skipped in dry-run /
        //    diagnostics (callers pass `recordRetrievalBoost = false`).
        if recordRetrievalBoost, !scoredHits.isEmpty {
            _ = try await queue.write { writeDB in
                for h in scoredHits {
                    try MemoryItem.recordRetrieval(memoryID: h.item.memoryID, now: now, in: writeDB)
                }
            }
        }

        return scoredHits
    }

    // MARK: - FTS5 BM25

    /// Returns `{memory_id → bm25 raw score}`. Lower BM25 = better fit in
    /// SQLite's `bm25()` function (it's a "distance" — we invert before
    /// normalizing).
    private static func ftsSearch(
        query: String,
        domain: String?,
        types: [MemoryType]?,
        in db: Database
    ) throws -> [MemoryID: Double] {
        let sanitized = ftsSanitize(query)
        if sanitized.isEmpty { return [:] }
        var sql = """
            SELECT mi.memory_id AS mid, bm25(memory_fts) AS bm
            FROM memory_fts
            JOIN memory_items mi ON mi.rowid = memory_fts.rowid
            WHERE memory_fts MATCH ?
              AND mi.strength_at_last_update > 0
        """
        var args: [DatabaseValueConvertible?] = [sanitized]
        if let domain {
            sql += " AND mi.domain = ?"
            args.append(domain)
        }
        if let types, !types.isEmpty {
            let placeholders = Array(repeating: "?", count: types.count).joined(separator: ",")
            sql += " AND mi.type IN (\(placeholders))"
            for t in types { args.append(t.rawValue) }
        }
        sql += " ORDER BY bm ASC LIMIT \(lexicalTopK)"
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

        // Invert bm25 (smaller is better in SQLite) → bigger is better.
        // We negate; the reranker normalizes against max.
        var out: [MemoryID: Double] = [:]
        for row in rows {
            let bm: Double = row["bm"]
            let mid: MemoryID = row["mid"]
            out[mid] = -bm  // invert so "better" → larger
        }
        return out
    }

    /// Strip characters FTS5 treats as operators / column filters when the
    /// user didn't intend that. We don't need full query-language passthrough
    /// for this use-case — agent and user-typed queries are plain phrases.
    private static func ftsSanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "\"*:^()-")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
        let tokens = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        if tokens.isEmpty { return "" }
        // Wrap as an OR-of-prefix query so partial words still match: "wei*"
        // catches "weight". Use NEAR-ish OR for recall.
        return tokens.map { "\($0)*" }.joined(separator: " OR ")
    }

    // MARK: - Vector prefilter

    /// Brute-force top-K cosine candidates from `memory_items`. Returns
    /// memory_ids only; the caller fetches full rows. If the query vector is
    /// nil (embedder unavailable), returns [].
    private static func semanticPrefilter(
        queryVec: [Float]?,
        domain: String?,
        types: [MemoryType]?,
        topK: Int,
        in db: Database
    ) throws -> [MemoryID] {
        guard let q = queryVec else { return [] }
        var sql = """
            SELECT memory_id, embedding
            FROM memory_items
            WHERE strength_at_last_update > 0
        """
        var args: [DatabaseValueConvertible?] = []
        if let domain {
            sql += " AND domain = ?"
            args.append(domain)
        }
        if let types, !types.isEmpty {
            let placeholders = Array(repeating: "?", count: types.count).joined(separator: ",")
            sql += " AND type IN (\(placeholders))"
            for t in types { args.append(t.rawValue) }
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        var scored: [(MemoryID, Float)] = []
        scored.reserveCapacity(rows.count)
        for row in rows {
            let blob: Data = row["embedding"]
            guard let v = Embedder.decodeBlob(blob) else { continue }
            let cos = Embedder.cosine(q, v)
            scored.append((row["memory_id"], cos))
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(topK).map { $0.0 }
    }

    // MARK: - Recency

    /// 1.0 at now, decays to ~0 over 90 days. Smooth exponential so a memory
    /// touched yesterday ranks above one from a month ago even with similar
    /// cosine.
    private static func recencyScore(_ at: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(at) / 86_400)
        return exp(-days / 30.0)  // half-life ~21 days
    }
}
