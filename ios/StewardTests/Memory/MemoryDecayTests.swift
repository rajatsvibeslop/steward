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

    // MARK: - Auto-invocation seam (v1.1 patch)

    /// `MemoryDecayJob.runPersistencePass(on:now:)` is the single internal
    /// seam invoked by both `BGTaskCoordinator.handleAppRefresh` /
    /// `handleProcessing` and the one-shot launch kick in `AppBootstrap`.
    /// This test asserts the seam writes through to the queue end-to-end —
    /// proving the wiring exercised by the BGTask refresh path actually
    /// decays + soft-deletes, not just the lower-level static method.
    func test_runPersistencePass_appliesDecayAndSoftDeletesViaQueue() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decay-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cfg = Configuration(); cfg.foreignKeysEnabled = true
        let q = try DatabaseQueue(
            path: dir.appendingPathComponent("steward.sqlite").path,
            configuration: cfg
        )
        try Migrations.migrator.migrate(q)

        let veryOld = Date(timeIntervalSince1970: 1_500_000_000)
        let item = MemoryItem(
            memoryID: "m_persist",
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
        try await q.write { db in try item.upsert(in: db) }

        let outcome = await MemoryDecayJob.runPersistencePass(on: q, now: Date())

        XCTAssertNotNil(outcome, "persistence pass should run against a healthy queue")
        XCTAssertEqual(outcome?.scanned, 1)
        XCTAssertEqual(outcome?.softDeleted, 1,
                       "ancient observation must fall below 0.05 and soft-delete")
        try await q.read { db in
            let s = try Double.fetchOne(
                db,
                sql: "SELECT strength_at_last_update FROM memory_items WHERE memory_id='m_persist'"
            )
            XCTAssertEqual(s, 0.0)
        }
    }

    /// Calling the persistence pass twice in immediate succession must be a
    /// no-op on the second run — both the BGTask refresh handler and the
    /// app-launch kick may fire on the same tick (foreground after refresh).
    /// Idempotence prevents redundant writes from amplifying clock skew.
    func test_runPersistencePass_isIdempotentWithinASecond() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decay-idem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cfg = Configuration(); cfg.foreignKeysEnabled = true
        let q = try DatabaseQueue(
            path: dir.appendingPathComponent("steward.sqlite").path,
            configuration: cfg
        )
        try Migrations.migrator.migrate(q)

        let now = Date()
        let item = MemoryItem(
            memoryID: "m_idem",
            type: .observation,
            text: "freshly stamped",
            embedding: Array(repeating: 0.1, count: 4),
            embeddingDim: 4,
            embeddingRevision: "rev",
            strengthAtLastUpdate: 1.0,
            lastStrengthUpdateAt: now,
            lastAccessedAt: nil,
            createdAt: now,
            expiresAt: nil,
            domain: nil,
            provenanceEventIDs: []
        )
        try await q.write { db in try item.upsert(in: db) }

        let first = await MemoryDecayJob.runPersistencePass(on: q, now: now)
        let second = await MemoryDecayJob.runPersistencePass(on: q, now: now)

        XCTAssertEqual(first?.updated, 0,
                       "freshly stamped row is < 1 day old; nothing to persist")
        XCTAssertEqual(second?.updated, 0, "second pass within the same second is a no-op")
    }
}
