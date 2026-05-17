//
//  SchemaTests.swift
//  StewardTests
//
//  Track A DoD: open a fresh DB and verify all tables + FTS5 virtual tables
//  exist. Also exercises that re-opening the same file is idempotent (the
//  migration must not destroy data on re-run).
//

import XCTest
import GRDB
@testable import Steward

final class SchemaTests: XCTestCase {

    // MARK: - Setup

    private func makeTempDBURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("steward.sqlite")
    }

    private func openMigrated(at url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try Migrations.migrator.migrate(queue)
        return queue
    }

    // MARK: - Table existence

    func test_allConcreteTablesExist() throws {
        let queue = try openMigrated(at: makeTempDBURL())
        let expected: Set<String> = [
            "events",
            "memory_items",
            "instruments",
            "commitments",
            "domains",
            "notifications",
            "sync_queue",
            "settings"
        ]
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%'"
            )
            let names = Set(rows.compactMap { $0["name"] as String? })
            for table in expected {
                XCTAssertTrue(names.contains(table), "Missing table: \(table). Got: \(names)")
            }
        }
    }

    func test_ftsVirtualTablesExist() throws {
        let queue = try openMigrated(at: makeTempDBURL())
        try queue.read { db in
            // FTS5 virtual tables register multiple shadow tables. We assert
            // that the user-facing virtual tables exist by querying them.
            _ = try Row.fetchAll(db, sql: "SELECT rowid FROM events_fts LIMIT 1")
            _ = try Row.fetchAll(db, sql: "SELECT rowid FROM memory_fts LIMIT 1")
        }
    }

    func test_ftsTriggersFire_onEventInsert() throws {
        let queue = try openMigrated(at: makeTempDBURL())
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO events (event_id, created_at, actor, kind, text, payload_json)
                VALUES ('evt1', 1, 'user', 'log_entry', 'I slept six hours', '{"hours":6}')
            """)
        }
        try queue.read { db in
            let hits = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM events_fts WHERE events_fts MATCH 'slept'"
            ) ?? 0
            XCTAssertEqual(hits, 1, "events_fts should index inserted event text")
        }
    }

    func test_ftsTriggersFire_onMemoryUpdate() throws {
        let queue = try openMigrated(at: makeTempDBURL())
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO memory_items (
                    memory_id, type, text, embedding, embedding_dim,
                    embedding_revision, strength_at_last_update,
                    last_strength_update_at, created_at
                ) VALUES ('m1', 'preference', 'avoid morning prompts', x'00', 0,
                          'test.rev', 1.0, 1, 1)
            """)
        }
        try queue.read { db in
            let hits = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_fts WHERE memory_fts MATCH 'morning'"
            ) ?? 0
            XCTAssertEqual(hits, 1)
        }

        try queue.write { db in
            try db.execute(sql: "UPDATE memory_items SET text = 'avoid evening prompts' WHERE memory_id = 'm1'")
        }
        try queue.read { db in
            let oldHits = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_fts WHERE memory_fts MATCH 'morning'"
            ) ?? 0
            let newHits = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_fts WHERE memory_fts MATCH 'evening'"
            ) ?? 0
            XCTAssertEqual(oldHits, 0, "old text should no longer be indexed")
            XCTAssertEqual(newHits, 1, "new text should be indexed")
        }
    }

    // MARK: - Schema integrity guards

    func test_eventActorCheckConstraint_rejectsAgentWithoutReasoning() throws {
        let queue = try openMigrated(at: makeTempDBURL())
        do {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO events (event_id, created_at, actor, kind, text)
                    VALUES ('bad', 1, 'agent:health', 'log_entry', 'no reasoning')
                """)
            }
            XCTFail("Should have rejected agent-actor row without reasoning")
        } catch {
            // Expected — CHECK constraint fired.
        }
    }

    func test_eventActorCheckConstraint_allowsUserWithoutReasoning() throws {
        let queue = try openMigrated(at: makeTempDBURL())
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO events (event_id, created_at, actor, kind, text)
                VALUES ('ok', 1, 'user', 'log_entry', 'plain user log')
            """)
        }
    }

    func test_settingsSingleRow() throws {
        let queue = try openMigrated(at: makeTempDBURL())
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM settings") ?? 0
            XCTAssertEqual(count, 1, "settings table should be seeded with id=1 row")
        }
        // CHECK (id = 1) rejects a second row.
        do {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO settings (id, settings_json) VALUES (2, '{}')")
            }
            XCTFail("Should have rejected second settings row")
        } catch {
            // Expected.
        }
    }

    // MARK: - Idempotence

    func test_migrationReRunIsIdempotent() throws {
        let url = makeTempDBURL()

        let q1 = try openMigrated(at: url)
        try q1.write { db in
            try db.execute(sql: """
                INSERT INTO events (event_id, created_at, actor, kind, text)
                VALUES ('persist-me', 1, 'user', 'log_entry', 'survives re-migration')
            """)
        }

        // Force-close and re-open. GRDB closes on dealloc; explicit close not
        // available across all platforms, so drop the reference and create a
        // new queue against the same file.
        _ = q1
        let q2 = try openMigrated(at: url)
        try q2.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT text FROM events WHERE event_id='persist-me'")
            XCTAssertEqual(row?["text"] as String?, "survives re-migration",
                           "re-running migrations on an existing DB must not destroy data")
        }
    }

    // MARK: - Index sanity

    func test_keyIndexesExist() throws {
        let queue = try openMigrated(at: makeTempDBURL())
        let expected: Set<String> = [
            "events_created_at",
            "events_domain",
            "events_instrument",
            "memory_domain",
            "memory_strength_lazy",
            "instruments_domain",
            "commitments_status",
            "notifications_scheduled",
            "sync_pending"
        ]
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'"
            )
            let names = Set(rows.compactMap { $0["name"] as String? })
            for index in expected {
                XCTAssertTrue(names.contains(index), "Missing index: \(index). Got: \(names)")
            }
        }
    }
}
