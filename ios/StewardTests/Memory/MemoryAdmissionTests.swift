//
//  MemoryAdmissionTests.swift
//  StewardTests
//
//  MemoryAdmissionPolicy edge cases. Cosine math runs through Embedder so
//  we exercise the BLOB encode/decode + vDSP pipeline at the same time.
//

import XCTest
import GRDB
@testable import Steward

final class MemoryAdmissionTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cfg = Configuration(); cfg.foreignKeysEnabled = true
        let q = try DatabaseQueue(path: dir.appendingPathComponent("steward.sqlite").path, configuration: cfg)
        try Migrations.migrator.migrate(q)
        return q
    }

    private func normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.map { $0 * $0 }.reduce(0, +))
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    private func makeMemory(
        id: String,
        type: MemoryType = .preference,
        text: String = "x",
        embedding: [Float],
        domain: String? = nil
    ) -> MemoryItem {
        let now = Date()
        return MemoryItem(
            memoryID: id,
            type: type,
            text: text,
            embedding: normalize(embedding),
            embeddingDim: embedding.count,
            embeddingRevision: "test.rev",
            strengthAtLastUpdate: 1.0,
            lastStrengthUpdateAt: now,
            lastAccessedAt: nil,
            createdAt: now,
            expiresAt: nil,
            domain: domain,
            provenanceEventIDs: []
        )
    }

    func test_admission_emptyDB_admitsCleanly() throws {
        let q = try makeDB()
        let prop = MemorySaveProposal(
            type: .preference,
            text: "i hate morning prompts before 9am",
            domain: nil,
            strength: 1.0,
            expiresAt: nil,
            provenanceEventIDs: []
        )
        let result = try q.read { db in
            try MemoryAdmissionPolicy.evaluate(prop, embedding: [0.6, 0.8], turnSaveCount: 0, now: Date(), in: db)
        }
        XCTAssertEqual(result, .admit)
    }

    func test_admission_perTurnCap_rejectsAtThree() throws {
        let q = try makeDB()
        let prop = MemorySaveProposal(
            type: .observation, text: "x", domain: nil, strength: 1.0, expiresAt: nil, provenanceEventIDs: []
        )
        let result = try q.read { db in
            try MemoryAdmissionPolicy.evaluate(prop, embedding: [0.6, 0.8], turnSaveCount: 3, now: Date(), in: db)
        }
        XCTAssertEqual(result, .rejectAdmissionCap)
    }

    func test_admission_detectsDuplicateAtHighCosine() throws {
        let q = try makeDB()
        let identical: [Float] = [0.6, 0.8]
        let existing = makeMemory(id: "m1", type: .preference, text: "no morning prompts", embedding: identical)
        try q.write { db in try existing.upsert(in: db) }

        let prop = MemorySaveProposal(
            type: .preference, text: "no morning prompts", domain: nil,
            strength: 1.0, expiresAt: nil, provenanceEventIDs: []
        )
        let result = try q.read { db in
            try MemoryAdmissionPolicy.evaluate(prop, embedding: normalize(identical), turnSaveCount: 0, now: Date(), in: db)
        }
        if case .rejectDuplicate(let existingID, let cosine) = result {
            XCTAssertEqual(existingID, "m1")
            XCTAssertGreaterThan(cosine, 0.94)
        } else {
            XCTFail("expected rejectDuplicate, got \(result)")
        }
    }

    func test_admission_contradictionFlagged_butAdmitted() throws {
        let q = try makeDB()
        // Use a clearly different but related vector (~0.87 cosine):
        // Build orthogonal-ish pair; rely on threshold tuning to land in
        // the 0.85..0.95 band.
        let a = normalize([1.0, 0.0])
        let b = normalize([0.88, 0.474]) // cos ≈ 0.88
        let existing = makeMemory(id: "m1", type: .preference, embedding: a)
        try q.write { db in try existing.upsert(in: db) }
        let prop = MemorySaveProposal(
            type: .preference, text: "fresh", domain: nil,
            strength: 1.0, expiresAt: nil, provenanceEventIDs: []
        )
        let result = try q.read { db in
            try MemoryAdmissionPolicy.evaluate(prop, embedding: b, turnSaveCount: 0, now: Date(), in: db)
        }
        if case .admitWithContradiction(let conflicts) = result {
            XCTAssertEqual(conflicts, ["m1"])
        } else {
            XCTFail("expected admitWithContradiction, got \(result)")
        }
    }

    func test_admission_ephemeralPhrase_rejected() throws {
        let q = try makeDB()
        let prop = MemorySaveProposal(
            type: .observation, text: "i'm hungry right now",
            domain: nil, strength: 1.0, expiresAt: nil, provenanceEventIDs: []
        )
        let result = try q.read { db in
            try MemoryAdmissionPolicy.evaluate(prop, embedding: [1, 0], turnSaveCount: 0, now: Date(), in: db)
        }
        if case .rejectEphemeral = result {
            // pass
        } else {
            XCTFail("expected rejectEphemeral, got \(result)")
        }
    }
}
