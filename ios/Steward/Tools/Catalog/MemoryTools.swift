//
//  MemoryTools.swift
//  Steward
//
//  Spec §8 memory tools: save / search / forget / strengthen / list_recent.
//  save runs through MemoryAdmissionPolicy first; results may be admit /
//  reject / admitWithContradiction. The contradiction flag is surfaced to
//  the agent so the next turn can reconcile.
//

import Foundation
import GRDB

// MARK: - memory.save

struct MemorySaveArgs: Codable, Equatable, Sendable {
    let text: String
    let type: MemoryType
    let domain: String?
    let strength: Double?
    let expiresAt: Date?
    let provenanceEventIds: [EventId]?
    /// How many memory.save calls have already landed in the current turn.
    /// The coordinator threads this through; if omitted we treat as zero
    /// (defensive — single-tool runs).
    let turnSaveCount: Int?
    let reasoning: String
    let actor: String
}

enum MemorySaveOutcome: String, Codable, Sendable, CaseIterable, Equatable {
    case admitted
    case admittedWithContradiction = "admitted_with_contradiction"
    case rejectedEphemeral = "rejected_ephemeral"
    case rejectedDuplicate = "rejected_duplicate"
    case rejectedAdmissionCap = "rejected_admission_cap"
    case rejectedEmbedderUnavailable = "rejected_embedder_unavailable"
}

struct MemorySaveResult: Codable, Equatable, Sendable {
    let outcome: MemorySaveOutcome
    let memoryId: MemoryId?
    let conflictingMemoryIds: [MemoryId]?
    let existingDuplicateId: MemoryId?
    let duplicateCosine: Double?
    let reason: String?
}

struct MemorySaveTool: LLMTool {
    let id: String = ToolId.memorySave.rawValue
    let description: String = "Save a durable, retrievable-by-similarity fact. Subject to admission policy."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["text", "type", "reasoning", "actor"],
      "properties": {
        "text": {"type": "string"},
        "type": {"type": "string", "enum": ["preference","constraint","lesson","observation","fact_about_user"]},
        "domain": {"type": ["string", "null"]},
        "strength": {"type": ["number", "null"], "minimum": 0, "maximum": 1},
        "expires_at": {"type": ["string", "null"], "format": "date-time"},
        "provenance_event_ids": {"type": ["array", "null"], "items": {"type": "string"}},
        "turn_save_count": {"type": ["integer", "null"], "minimum": 0},
        "reasoning": {"type": "string"},
        "actor": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let embedder: Embedder
    let now: @Sendable () -> Date

    init(provider: DatabaseProvider = .shared,
         embedder: Embedder = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.embedder = embedder
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(MemorySaveArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()

        // Embed first — if the model is unavailable we surface a typed
        // outcome instead of falling back to a zero vector (would corrupt
        // future dedup checks).
        let vec: [Float]
        do {
            vec = try await embedder.embed(args.text)
        } catch {
            return try ToolJSON.encode(MemorySaveResult(
                outcome: .rejectedEmbedderUnavailable,
                memoryId: nil,
                conflictingMemoryIds: nil,
                existingDuplicateId: nil,
                duplicateCosine: nil,
                reason: String(describing: error)
            ))
        }
        let revision = try await embedder.currentRevision()

        let proposal = MemorySaveProposal(
            type: args.type,
            text: args.text,
            domain: args.domain,
            strength: min(max(args.strength ?? 1.0, 0), 1),
            expiresAt: args.expiresAt,
            provenanceEventIds: args.provenanceEventIds ?? []
        )
        let turnSaveCount = args.turnSaveCount ?? 0
        let db = try await provider.database()

        let outcome: AdmissionResult = try await db.read { dbase in
            try MemoryAdmissionPolicy.evaluate(
                proposal,
                embedding: vec,
                turnSaveCount: turnSaveCount,
                now: timestamp,
                in: dbase
            )
        }

        switch outcome {
        case .rejectAdmissionCap:
            return try ToolJSON.encode(MemorySaveResult(
                outcome: .rejectedAdmissionCap,
                memoryId: nil, conflictingMemoryIds: nil,
                existingDuplicateId: nil, duplicateCosine: nil,
                reason: "max \(MemoryAdmissionPolicy.perTurnAdmissionCap) saves per turn"
            ))
        case .rejectEphemeral(let reason):
            return try ToolJSON.encode(MemorySaveResult(
                outcome: .rejectedEphemeral,
                memoryId: nil, conflictingMemoryIds: nil,
                existingDuplicateId: nil, duplicateCosine: nil,
                reason: reason
            ))
        case .rejectDuplicate(let existing, let cosine):
            return try ToolJSON.encode(MemorySaveResult(
                outcome: .rejectedDuplicate,
                memoryId: nil, conflictingMemoryIds: nil,
                existingDuplicateId: existing, duplicateCosine: cosine,
                reason: "duplicate of \(existing) at cosine \(cosine)"
            ))
        case .admit, .admitWithContradiction:
            let id = ULID.generate(now: timestamp)
            let item = MemoryItem(
                memoryId: id,
                type: args.type,
                text: args.text,
                embedding: vec,
                embeddingDim: vec.count,
                embeddingRevision: revision.stringValue,
                strengthAtLastUpdate: proposal.strength,
                lastStrengthUpdateAt: timestamp,
                lastAccessedAt: nil,
                createdAt: timestamp,
                expiresAt: args.expiresAt,
                domain: args.domain,
                provenanceEventIds: proposal.provenanceEventIds
            )
            let conflicts: [MemoryId]? = {
                if case .admitWithContradiction(let c) = outcome { return c }
                return nil
            }()
            struct SavePayload: Encodable {
                let memoryId: String
                let type: String
                let contradictions: [String]
            }
            let payload = SavePayload(
                memoryId: id,
                type: args.type.rawValue,
                contradictions: conflicts ?? []
            )
            try await db.write { dbase in
                try item.upsert(in: dbase)
                try EventLog.append(
                    actor: actor,
                    kind: "memory_save",
                    payload: payload,
                    text: args.text,
                    domain: args.domain,
                    source: "tool",
                    reasoning: args.reasoning,
                    at: timestamp,
                    in: dbase
                )
            }
            let result = MemorySaveResult(
                outcome: conflicts == nil ? .admitted : .admittedWithContradiction,
                memoryId: id,
                conflictingMemoryIds: conflicts,
                existingDuplicateId: nil,
                duplicateCosine: nil,
                reason: nil
            )
            return try ToolJSON.encode(result)
        }
    }
}

// MARK: - memory.search

struct MemorySearchArgs: Codable, Equatable, Sendable {
    let query: String
    let domain: String?
    let types: [MemoryType]?
    let limit: Int?
}

struct MemorySearchHit: Codable, Equatable, Sendable {
    let memoryId: MemoryId
    let type: MemoryType
    let text: String
    let domain: String?
    let score: Double
    let cosine: Double
    let bm25Normalized: Double
    let recency: Double
    let typeBonus: Double
    let effectiveStrength: Double
    let createdAt: Date
}

struct MemorySearchResult: Codable, Equatable, Sendable {
    let hits: [MemorySearchHit]
}

struct MemorySearchTool: LLMTool {
    let id: String = ToolId.memorySearch.rawValue
    let description: String = "Hybrid memory retrieval (FTS5 + NLEmbedding cosine + recency + type bias)."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["query"],
      "properties": {
        "query": {"type": "string"},
        "domain": {"type": ["string", "null"]},
        "types": {"type": ["array", "null"], "items": {"type": "string"}},
        "limit": {"type": ["integer", "null"], "minimum": 1, "maximum": 50}
      }
    }
    """

    let provider: DatabaseProvider
    let embedder: Embedder
    let now: @Sendable () -> Date
    init(provider: DatabaseProvider = .shared,
         embedder: Embedder = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.embedder = embedder
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(MemorySearchArgs.self, from: argsJSON)
        let limit = min(max(args.limit ?? 8, 1), 50)
        let timestamp = now()
        let db = try await provider.database()
        let hits = try await MemoryRetriever.retrieve(
            query: args.query,
            domain: args.domain,
            types: args.types,
            limit: limit,
            now: timestamp,
            in: db,
            embedder: embedder
        )
        let mapped = hits.map {
            MemorySearchHit(
                memoryId: $0.item.memoryId,
                type: $0.item.type,
                text: $0.item.text,
                domain: $0.item.domain,
                score: $0.score,
                cosine: $0.cosine,
                bm25Normalized: $0.bm25Normalized,
                recency: $0.recency,
                typeBonus: $0.typeBonus,
                effectiveStrength: $0.effectiveStrength,
                createdAt: $0.item.createdAt
            )
        }
        return try ToolJSON.encode(MemorySearchResult(hits: mapped))
    }
}

// MARK: - memory.forget

struct MemoryForgetArgs: Codable, Equatable, Sendable {
    let memoryId: MemoryId
    let reason: String
    let reasoning: String
    let actor: String
}

struct MemoryForgetResult: Codable, Equatable, Sendable {
    let memoryId: MemoryId
    let forgottenAt: Date
}

struct MemoryForgetTool: LLMTool {
    let id: String = ToolId.memoryForget.rawValue
    let description: String = "Soft-delete a memory (strength → 0). The row stays for provenance; reranker stops surfacing it."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["memory_id", "reason", "reasoning", "actor"],
      "properties": {
        "memory_id": {"type": "string"},
        "reason": {"type": "string"},
        "reasoning": {"type": "string"},
        "actor": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let now: @Sendable () -> Date
    init(provider: DatabaseProvider = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(MemoryForgetArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let db = try await provider.database()
        try await db.write { dbase in
            try MemoryItem.softForget(memoryId: args.memoryId, now: timestamp, in: dbase)
            try EventLog.append(
                actor: actor,
                kind: "memory_forget",
                payload: ["memory_id": args.memoryId],
                text: args.reason,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(MemoryForgetResult(memoryId: args.memoryId, forgottenAt: timestamp))
    }
}

// MARK: - memory.strengthen

struct MemoryStrengthenArgs: Codable, Equatable, Sendable {
    let memoryId: MemoryId
    let reasoning: String
    let actor: String
}

struct MemoryStrengthenResult: Codable, Equatable, Sendable {
    let memoryId: MemoryId
    let strengthenedAt: Date
}

struct MemoryStrengthenTool: LLMTool {
    let id: String = ToolId.memoryStrengthen.rawValue
    let description: String = "Bump a memory's strength by +0.20 (capped at 1.0)."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["memory_id", "reasoning", "actor"],
      "properties": {
        "memory_id": {"type": "string"},
        "reasoning": {"type": "string"},
        "actor": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let now: @Sendable () -> Date
    init(provider: DatabaseProvider = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(MemoryStrengthenArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let db = try await provider.database()
        try await db.write { dbase in
            try MemoryItem.recordConfirmation(memoryId: args.memoryId, now: timestamp, in: dbase)
            try EventLog.append(
                actor: actor,
                kind: "memory_strengthen",
                payload: ["memory_id": args.memoryId],
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(MemoryStrengthenResult(memoryId: args.memoryId, strengthenedAt: timestamp))
    }
}

// MARK: - memory.list_recent

struct MemoryListRecentArgs: Codable, Equatable, Sendable {
    let limit: Int?
    let domain: String?
}

struct MemoryListRecentItem: Codable, Equatable, Sendable {
    let memoryId: MemoryId
    let type: MemoryType
    let text: String
    let domain: String?
    let createdAt: Date
    let strengthAtLastUpdate: Double
    let effectiveStrength: Double
}

struct MemoryListRecentResult: Codable, Equatable, Sendable {
    let items: [MemoryListRecentItem]
}

struct MemoryListRecentTool: LLMTool {
    let id: String = ToolId.memoryListRecent.rawValue
    let description: String = "List recent memories by created_at desc."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "properties": {
        "limit": {"type": ["integer", "null"], "minimum": 1, "maximum": 100},
        "domain": {"type": ["string", "null"]}
      }
    }
    """

    let provider: DatabaseProvider
    let now: @Sendable () -> Date
    init(provider: DatabaseProvider = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(MemoryListRecentArgs.self, from: argsJSON)
        let limit = min(max(args.limit ?? 20, 1), 100)
        let timestamp = now()
        let db = try await provider.database()
        let items: [MemoryListRecentItem] = try await db.read { dbase in
            var sql = """
                SELECT memory_id, type, text, embedding, embedding_dim, embedding_revision,
                       strength_at_last_update, last_strength_update_at, last_accessed_at,
                       created_at, expires_at, domain, provenance_event_ids
                FROM memory_items
                WHERE strength_at_last_update > 0
            """
            var sqlArgs: [DatabaseValueConvertible?] = []
            if let domain = args.domain {
                sql += " AND domain = ?"
                sqlArgs.append(domain)
            }
            sql += " ORDER BY created_at DESC LIMIT \(limit)"
            let rows = try Row.fetchAll(dbase, sql: sql, arguments: StatementArguments(sqlArgs))
            return rows.compactMap { row -> MemoryListRecentItem? in
                guard let item = try? mapRowToMemoryItem(row) else { return nil }
                return MemoryListRecentItem(
                    memoryId: item.memoryId,
                    type: item.type,
                    text: item.text,
                    domain: item.domain,
                    createdAt: item.createdAt,
                    strengthAtLastUpdate: item.strengthAtLastUpdate,
                    effectiveStrength: item.effectiveStrength(now: timestamp)
                )
            }
        }
        return try ToolJSON.encode(MemoryListRecentResult(items: items))
    }

    /// Local copy of the row mapper used by MemoryItem.fetchOne (kept
    /// private to avoid widening MemoryItem's public surface for this
    /// niche tool path).
    private func mapRowToMemoryItem(_ row: Row) throws -> MemoryItem {
        let blob: Data = row["embedding"]
        guard let vec = Embedder.decodeBlob(blob) else {
            throw MemoryStoreError.corruptEmbeddingBlob(memoryId: row["memory_id"])
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
            provenanceEventIds: []
        )
    }
}
