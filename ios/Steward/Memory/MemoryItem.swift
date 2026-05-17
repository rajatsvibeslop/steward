//
//  MemoryItem.swift
//  Steward
//
//  Strongly-typed mirror of a `memory_items` row, with the lazy-decay
//  helper from addendum §1.5. The reranker calls `effectiveStrength(now:)`
//  on every retrieval; the nightly job persists the freshly-computed value
//  back so indexed `ORDER BY strength_at_last_update` stays honest.
//

import Foundation
import GRDB

/// Memory categorization per addendum §1.5. The DB column is TEXT — these
/// raw values are the on-disk wire format.
enum MemoryType: String, Codable, Sendable, CaseIterable, Equatable {
    case preference
    case constraint
    case lesson
    case observation
    case factAboutUser = "fact_about_user"

    /// Type bias used by the reranker (constraint > preference > lesson > observation).
    /// Numbers chosen so a constraint just barely outranks a preference even
    /// when the cosine score is identical; tweakable in `Memory/Tuning.swift`
    /// later if we need to.
    var rerankerBonus: Double {
        switch self {
        case .constraint:     return 1.0
        case .preference:     return 0.7
        case .lesson:         return 0.5
        case .factAboutUser:  return 0.4
        case .observation:    return 0.3
        }
    }

    /// Per-day decay multiplier (addendum §1.5).
    var dailyDecayMultiplier: Double {
        switch self {
        case .constraint:     return 0.9995
        case .factAboutUser:  return 0.999
        case .preference:     return 0.998
        case .lesson:         return 0.995
        case .observation:    return 0.99
        }
    }
}

/// In-memory shape of one row. Persisted via `MemoryItem.upsert(db:)`.
struct MemoryItem: Equatable, Sendable, Codable {
    let memoryId: MemoryId
    let type: MemoryType
    let text: String
    /// L2-normalized Float32 vector. Length must match `embeddingDim`.
    let embedding: [Float]
    let embeddingDim: Int
    let embeddingRevision: String
    let strengthAtLastUpdate: Double
    let lastStrengthUpdateAt: Date
    let lastAccessedAt: Date?
    let createdAt: Date
    let expiresAt: Date?
    let domain: String?
    let provenanceEventIds: [EventId]

    /// Lazy decay per addendum §1.5. Computed at retrieval; nightly job
    /// persists back for indexed sort queries.
    func effectiveStrength(now: Date) -> Double {
        let daysSince = max(0, now.timeIntervalSince(lastStrengthUpdateAt) / 86_400)
        let perDay = type.dailyDecayMultiplier
        let value = strengthAtLastUpdate * pow(perDay, daysSince)
        return min(1.0, max(0.0, value))
    }

    /// True iff lazy strength has fallen below the soft-delete threshold
    /// (addendum §1.5 — 0.05). The nightly job uses this to move rows to
    /// archive; the reranker ignores rows already below threshold.
    func isExpired(now: Date) -> Bool {
        if let exp = expiresAt, now >= exp { return true }
        return effectiveStrength(now: now) < 0.05
    }
}

// MARK: - GRDB row mapping

extension MemoryItem {

    /// Fetch by primary key. Returns nil if missing.
    static func fetchOne(db: Database, memoryId: MemoryId) throws -> MemoryItem? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT memory_id, type, text, embedding, embedding_dim, embedding_revision,
                       strength_at_last_update, last_strength_update_at, last_accessed_at,
                       created_at, expires_at, domain, provenance_event_ids
                FROM memory_items
                WHERE memory_id = ?
            """,
            arguments: [memoryId]
        ) else { return nil }
        return try fromRow(row)
    }

    /// Fetch many by primary keys (in-clause). Order is not guaranteed.
    static func fetchMany(db: Database, memoryIds: [MemoryId]) throws -> [MemoryItem] {
        guard !memoryIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: memoryIds.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT memory_id, type, text, embedding, embedding_dim, embedding_revision,
                       strength_at_last_update, last_strength_update_at, last_accessed_at,
                       created_at, expires_at, domain, provenance_event_ids
                FROM memory_items
                WHERE memory_id IN (\(placeholders))
            """,
            arguments: StatementArguments(memoryIds)
        )
        return try rows.map(fromRow)
    }

    /// Insert (or fully replace) a row. Caller runs inside a `db.write { }`.
    func upsert(in db: Database) throws {
        let createdMs = Int64(createdAt.timeIntervalSince1970 * 1000)
        let lastUpdMs = Int64(lastStrengthUpdateAt.timeIntervalSince1970 * 1000)
        let lastAcc: Int64? = lastAccessedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        let expMs: Int64? = expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        let provenance = (try? JSONEncoder().encode(provenanceEventIds))
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO memory_items (
                    memory_id, type, text, embedding, embedding_dim, embedding_revision,
                    strength_at_last_update, last_strength_update_at, last_accessed_at,
                    created_at, expires_at, domain, provenance_event_ids
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                memoryId,
                type.rawValue,
                text,
                Embedder.encodeBlob(embedding),
                embeddingDim,
                embeddingRevision,
                strengthAtLastUpdate,
                lastUpdMs,
                lastAcc,
                createdMs,
                expMs,
                domain,
                provenance
            ]
        )
    }

    /// Bump `last_accessed_at` and apply the retrieval boost (addendum §1.5:
    /// +0.05 on retrieval, capped at 1.0). Persists strength + bumps
    /// `last_strength_update_at` so the lazy formula stays consistent.
    static func recordRetrieval(memoryId: MemoryId, now: Date, in db: Database) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try db.execute(
            sql: """
                UPDATE memory_items
                SET last_accessed_at = ?,
                    strength_at_last_update = MIN(1.0, strength_at_last_update + 0.05),
                    last_strength_update_at = ?
                WHERE memory_id = ?
            """,
            arguments: [nowMs, nowMs, memoryId]
        )
    }

    /// Confirmation boost (addendum §1.5: +0.20, capped at 1.0). Called by
    /// `memory.strengthen`.
    static func recordConfirmation(memoryId: MemoryId, now: Date, in db: Database) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try db.execute(
            sql: """
                UPDATE memory_items
                SET strength_at_last_update = MIN(1.0, strength_at_last_update + 0.20),
                    last_strength_update_at = ?
                WHERE memory_id = ?
            """,
            arguments: [nowMs, memoryId]
        )
    }

    /// Soft-delete: zero out strength. Hard reject #10 prohibits DELETE on
    /// events; memory rows we treat the same — instead of DELETE, we drop
    /// strength to 0 so the reranker stops surfacing it but the row stays
    /// referenceable from provenance trails.
    static func softForget(memoryId: MemoryId, now: Date, in db: Database) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try db.execute(
            sql: """
                UPDATE memory_items
                SET strength_at_last_update = 0.0,
                    last_strength_update_at = ?
                WHERE memory_id = ?
            """,
            arguments: [nowMs, memoryId]
        )
    }

    /// Row → MemoryItem. Used by all fetch paths.
    private static func fromRow(_ row: Row) throws -> MemoryItem {
        let blob: Data = row["embedding"]
        guard let vec = Embedder.decodeBlob(blob) else {
            throw MemoryStoreError.corruptEmbeddingBlob(memoryId: row["memory_id"])
        }
        let provenance: [EventId]
        if let json: String = row["provenance_event_ids"],
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([EventId].self, from: data) {
            provenance = decoded
        } else {
            provenance = []
        }
        guard let type = MemoryType(rawValue: row["type"]) else {
            throw MemoryStoreError.unknownMemoryType(raw: row["type"])
        }
        return MemoryItem(
            memoryId: row["memory_id"],
            type: type,
            text: row["text"],
            embedding: vec,
            embeddingDim: row["embedding_dim"],
            embeddingRevision: row["embedding_revision"],
            strengthAtLastUpdate: row["strength_at_last_update"],
            lastStrengthUpdateAt: Date(timeIntervalSince1970: Double(row["last_strength_update_at"] as Int64) / 1000),
            lastAccessedAt: (row["last_accessed_at"] as Int64?).map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            },
            createdAt: Date(timeIntervalSince1970: Double(row["created_at"] as Int64) / 1000),
            expiresAt: (row["expires_at"] as Int64?).map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            },
            domain: row["domain"],
            provenanceEventIds: provenance
        )
    }
}

enum MemoryStoreError: Error, CustomStringConvertible, Equatable {
    case corruptEmbeddingBlob(memoryId: MemoryId)
    case unknownMemoryType(raw: String)

    var description: String {
        switch self {
        case .corruptEmbeddingBlob(let id):
            return "memory \(id) has a non-Float32 BLOB embedding"
        case .unknownMemoryType(let r):
            return "memory_items.type='\(r)' is not a known MemoryType"
        }
    }
}
