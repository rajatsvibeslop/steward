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
    let memoryID: MemoryID
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
    let provenanceEventIDs: [EventID]

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

    enum CodingKeys: String, CodingKey {
        case memoryID = "memory_id"
        case type
        case text
        case embedding
        case embeddingDim = "embedding_dim"
        case embeddingRevision = "embedding_revision"
        case strengthAtLastUpdate = "strength_at_last_update"
        case lastStrengthUpdateAt = "last_strength_update_at"
        case lastAccessedAt = "last_accessed_at"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case domain
        case provenanceEventIDs = "provenance_event_i_ds"
    }
}

// MARK: - GRDB row mapping

extension MemoryItem {

    /// Fetch by primary key. Returns nil if missing.
    static func fetchOne(db: Database, memoryID: MemoryID) throws -> MemoryItem? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT memory_id, type, text, embedding, embedding_dim, embedding_revision,
                       strength_at_last_update, last_strength_update_at, last_accessed_at,
                       created_at, expires_at, domain, provenance_event_ids
                FROM memory_items
                WHERE memory_id = ?
            """,
            arguments: [memoryID]
        ) else { return nil }
        return try fromRow(row)
    }

    /// Fetch many by primary keys (in-clause). Order is not guaranteed.
    static func fetchMany(db: Database, memoryIDs: [MemoryID]) throws -> [MemoryItem] {
        guard !memoryIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: memoryIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT memory_id, type, text, embedding, embedding_dim, embedding_revision,
                       strength_at_last_update, last_strength_update_at, last_accessed_at,
                       created_at, expires_at, domain, provenance_event_ids
                FROM memory_items
                WHERE memory_id IN (\(placeholders))
            """,
            arguments: StatementArguments(memoryIDs)
        )
        return try rows.map(fromRow)
    }

    /// Insert (or fully replace) a row. Caller runs inside a `db.write { }`.
    func upsert(in db: Database) throws {
        let createdMs = Int64(createdAt.timeIntervalSince1970 * 1000)
        let lastUpdMs = Int64(lastStrengthUpdateAt.timeIntervalSince1970 * 1000)
        let lastAcc: Int64? = lastAccessedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        let expMs: Int64? = expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        let provenance = (try? JSONEncoder().encode(provenanceEventIDs))
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
                memoryID,
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
    static func recordRetrieval(memoryID: MemoryID, now: Date, in db: Database) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try db.execute(
            sql: """
                UPDATE memory_items
                SET last_accessed_at = ?,
                    strength_at_last_update = MIN(1.0, strength_at_last_update + 0.05),
                    last_strength_update_at = ?
                WHERE memory_id = ?
            """,
            arguments: [nowMs, nowMs, memoryID]
        )
    }

    /// Confirmation boost (addendum §1.5: +0.20, capped at 1.0). Called by
    /// `memory.strengthen`.
    static func recordConfirmation(memoryID: MemoryID, now: Date, in db: Database) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try db.execute(
            sql: """
                UPDATE memory_items
                SET strength_at_last_update = MIN(1.0, strength_at_last_update + 0.20),
                    last_strength_update_at = ?
                WHERE memory_id = ?
            """,
            arguments: [nowMs, memoryID]
        )
    }

    /// Soft-delete: zero out strength. Hard reject #10 prohibits DELETE on
    /// events; memory rows we treat the same — instead of DELETE, we drop
    /// strength to 0 so the reranker stops surfacing it but the row stays
    /// referenceable from provenance trails.
    static func softForget(memoryID: MemoryID, now: Date, in db: Database) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try db.execute(
            sql: """
                UPDATE memory_items
                SET strength_at_last_update = 0.0,
                    last_strength_update_at = ?
                WHERE memory_id = ?
            """,
            arguments: [nowMs, memoryID]
        )
    }

    /// Row → MemoryItem. Used by all fetch paths.
    private static func fromRow(_ row: Row) throws -> MemoryItem {
        let blob: Data = row["embedding"]
        guard let vec = Embedder.decodeBlob(blob) else {
            throw MemoryStoreError.corruptEmbeddingBlob(memoryID: row["memory_id"])
        }
        let provenance: [EventID]
        if let json: String = row["provenance_event_ids"],
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([EventID].self, from: data) {
            provenance = decoded
        } else {
            provenance = []
        }
        guard let type = MemoryType(rawValue: row["type"]) else {
            throw MemoryStoreError.unknownMemoryType(raw: row["type"])
        }
        return MemoryItem(
            memoryID: row["memory_id"],
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
            provenanceEventIDs: provenance
        )
    }
}

enum MemoryStoreError: Error, CustomStringConvertible, Equatable {
    case corruptEmbeddingBlob(memoryID: MemoryID)
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
