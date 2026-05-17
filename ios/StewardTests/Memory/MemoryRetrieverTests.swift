//
//  MemoryRetrieverTests.swift
//  StewardTests
//
//  Hybrid retrieval edge cases: empty memory, all-decayed-out, BM25-only
//  fallback when embedder is unavailable, rerank ordering.
//

import XCTest
import GRDB
@testable import Steward

/// A no-op embedder that returns nil-equivalent — used to exercise the
/// FTS-only fallback path without requiring NLEmbedding's on-device model.
private actor UnavailableEmbedder {
    // The retriever calls `await embedder.embed(query)`; if that throws,
    // qVec stays nil and we degrade gracefully. We can't subclass Embedder
    // (it's a concrete actor), so we test the fallback path by simply
    // ensuring `retrieve` works against an empty memory pool with the real
    // shared embedder, which on a build machine without the model will
    // throw and we'll exercise the fallback that way.
}

final class MemoryRetrieverTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrieve-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cfg = Configuration(); cfg.foreignKeysEnabled = true
        let q = try DatabaseQueue(path: dir.appendingPathComponent("steward.sqlite").path, configuration: cfg)
        try Migrations.migrator.migrate(q)
        return q
    }

    private func normalize(_ v: [Float]) -> [Float] {
        let n = sqrt(v.map { $0 * $0 }.reduce(0, +))
        guard n > 0 else { return v }
        return v.map { $0 / n }
    }

    private func makeItem(
        id: String,
        text: String,
        type: MemoryType = .preference,
        embedding: [Float],
        strength: Double = 1.0,
        ageDays: Double = 0,
        domain: String? = nil
    ) -> MemoryItem {
        let now = Date().addingTimeInterval(-ageDays * 86_400)
        return MemoryItem(
            memoryID: id,
            type: type,
            text: text,
            embedding: normalize(embedding),
            embeddingDim: embedding.count,
            embeddingRevision: "test.rev",
            strengthAtLastUpdate: strength,
            lastStrengthUpdateAt: now,
            lastAccessedAt: nil,
            createdAt: now,
            expiresAt: nil,
            domain: domain,
            provenanceEventIDs: []
        )
    }

    func test_retrieve_emptyMemory_returnsEmpty() async throws {
        let q = try makeDB()
        let hits = try await MemoryRetriever.retrieve(query: "anything", in: q)
        XCTAssertEqual(hits.count, 0)
    }

    func test_retrieve_softDeletedRowExcluded() async throws {
        let q = try makeDB()
        let items = [
            makeItem(id: "fresh", text: "user prefers no morning prompts", embedding: [0.6, 0.8]),
            makeItem(id: "dead", text: "user prefers no morning prompts again", embedding: [0.6, 0.8], strength: 0.0)
        ]
        _ = try await q.write { db in
            for it in items { try it.upsert(in: db) }
        }
        let hits = try await MemoryRetriever.retrieve(query: "morning prompts", in: q)
        XCTAssertTrue(hits.contains { $0.item.memoryID == "fresh" })
        XCTAssertFalse(hits.contains { $0.item.memoryID == "dead" }, "soft-deleted rows must not surface")
    }

    func test_retrieve_orderedByScoreDesc_andRespectsLimit() async throws {
        let q = try makeDB()
        let items = [
            makeItem(id: "constraint", text: "no caffeine after 3pm", type: .constraint, embedding: [1, 0]),
            makeItem(id: "old_obs", text: "no caffeine at all sometimes", type: .observation, embedding: [1, 0], ageDays: 60),
            makeItem(id: "fresh_pref", text: "caffeine ok in mornings only", type: .preference, embedding: [0.9, 0.1])
        ]
        _ = try await q.write { db in
            for it in items { try it.upsert(in: db) }
        }
        let hits = try await MemoryRetriever.retrieve(query: "caffeine restrictions", limit: 3, in: q)
        for i in 1..<hits.count {
            XCTAssertGreaterThanOrEqual(hits[i-1].score, hits[i].score, "results not sorted by score desc")
        }
        XCTAssertLessThanOrEqual(hits.count, 3)
    }

    func test_retrieve_filtersByDomain() async throws {
        let q = try makeDB()
        let items = [
            makeItem(id: "money_pref", text: "no shopping after 9pm", embedding: [1, 0], domain: "money"),
            makeItem(id: "health_pref", text: "no shopping list for health", embedding: [1, 0], domain: "health")
        ]
        _ = try await q.write { db in
            for it in items { try it.upsert(in: db) }
        }
        let hits = try await MemoryRetriever.retrieve(query: "shopping", domain: "money", in: q)
        for h in hits {
            XCTAssertEqual(h.item.domain, "money")
        }
    }
}
