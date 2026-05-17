//
//  MemoryDecayTests.swift
//  StewardTests
//
//  Covers lazy decay (addendum §1.5) + the nightly persist job.
//

import XCTest
import GRDB
@testable import Steward

final class MemoryDecayTests: XCTestCase {

    func test_effectiveStrength_constraintDecaysSlowly() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let later = created.addingTimeInterval(86_400 * 30) // 30 days
        let item = MemoryItem(
            memoryID: "m1",
            type: .constraint,
            text: "no peanuts",
            embedding: Array(repeating: 0.1, count: 8),
            embeddingDim: 8,
            embeddingRevision: "rev",
            strengthAtLastUpdate: 1.0,
            lastStrengthUpdateAt: created,
            lastAccessedAt: nil,
            createdAt: created,
            expiresAt: nil,
            domain: nil,
            provenanceEventIDs: []
        )
        let s = item.effectiveStrength(now: later)
        // 0.9995^30 ≈ 0.9851
        XCTAssertEqual(s, 0.9851, accuracy: 0.005)
    }

    func test_effectiveStrength_observationDecaysQuickly() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let later = created.addingTimeInterval(86_400 * 30)
        let item = MemoryItem(
            memoryID: "m2",
            type: .observation,
            text: "noticed user is tired on Mondays",
            embedding: Array(repeating: 0.1, count: 8),
            embeddingDim: 8,
            embeddingRevision: "rev",
            strengthAtLastUpdate: 1.0,
            lastStrengthUpdateAt: created,
            lastAccessedAt: nil,
            createdAt: created,
            expiresAt: nil,
            domain: nil,
            provenanceEventIDs: []
        )
        let s = item.effectiveStrength(now: later)
        // 0.99^30 ≈ 0.7397
        XCTAssertEqual(s, 0.7397, accuracy: 0.01)
    }

    func test_isExpired_belowThresholdSoftDeleted() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let item = MemoryItem(
            memoryID: "m3",
            type: .observation,
            text: "old",
            embedding: [0.1],
            embeddingDim: 1,
            embeddingRevision: "rev",
            strengthAtLastUpdate: 0.04,
            lastStrengthUpdateAt: created,
            lastAccessedAt: nil,
            createdAt: created,
            expiresAt: nil,
            domain: nil,
            provenanceEventIDs: []
        )
        XCTAssertTrue(item.isExpired(now: created))
    }

    // MARK: - Nightly job

    func test_decayJob_persistsAndSoftDeletes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cfg = Configuration(); cfg.foreignKeysEnabled = true
        let q = try DatabaseQueue(path: dir.appendingPathComponent("steward.sqlite").path, configuration: cfg)
        try Migrations.migrator.migrate(q)

        let veryOld = Date(timeIntervalSince1970: 1_500_000_000)  // years ago
        let item = MemoryItem(
            memoryID: "m_old",
            type: .observation,
            text: "ancient observation",
            embedding: Array(repeating: 0.1, count: 4),
            embeddingDim: 4,
            embeddingRevision: "rev",
            strengthAtLastUpdate: 1.0,
            lastStrengthUpdateAt: veryOld,
            lastAccessedAt: nil,
            createdAt: veryOld,
            expiresAt: nil,
            domain: nil,
            provenanceEventIDs: []
        )
        try q.write { db in try item.upsert(in: db) }

        let outcome = try q.write { db in
            try MemoryDecayJob.run(now: Date(), in: db)
        }
        XCTAssertEqual(outcome.scanned, 1)
        XCTAssertEqual(outcome.softDeleted, 1, "ancient observation should fall below 0.05")
        try q.read { db in
            let s = try Double.fetchOne(db, sql: "SELECT strength_at_last_update FROM memory_items WHERE memory_id='m_old'")
            XCTAssertEqual(s, 0.0)
        }
    }
}
