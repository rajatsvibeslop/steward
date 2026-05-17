//
//  InstrumentRegistryTests.swift
//  StewardTests
//
//  Exercises the registry's full DB round-trip: dispatchApply on a real
//  GRDB queue, state-version migration, error surfaces.
//

import XCTest
import GRDB
@testable import Steward

final class InstrumentRegistryTests: XCTestCase {

    private func makeTempDB() throws -> DatabaseQueue {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cfg = Configuration(); cfg.foreignKeysEnabled = true
        let q = try DatabaseQueue(path: dir.appendingPathComponent("steward.sqlite").path, configuration: cfg)
        try Migrations.migrator.migrate(q)
        return q
    }

    override func setUp() {
        super.setUp()
        InstrumentRegistry._resetForTesting()
        InstrumentRegistry.bootstrapAll()
    }

    func test_initialStateAndDispatchApply_roundTripsBoundedBudget() throws {
        let q = try makeTempDB()
        let now = ISO8601DateFormatter().date(from: "2026-05-17T10:00:00Z")!
        let def = BoundedBudget.Definition(unit: "USD", period: .daily, limit: 100, rollover: false)
        let defJSON = String(data: try JSONEncoder().encode(def), encoding: .utf8)!
        let initial = try InstrumentRegistry.initialStateJSON(forKind: "bounded_budget", definitionJSON: defJSON, now: now)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try q.write { db in
            try db.execute(
                sql: """
                    INSERT INTO instruments
                    (instrument_id, domain, kind, name, definition_json, state_json,
                     state_version, created_at, last_updated_at)
                    VALUES ('i1', 'money', 'bounded_budget', 'Discretionary', ?, ?, 1, ?, ?)
                """,
                arguments: [defJSON, initial, nowMs, nowMs]
            )
        }

        let envelope = """
        {
          "actor": "agent:money",
          "createdAt": "2026-05-17T12:00:00Z",
          "eventID": "evt-1",
          "instrumentID": "i1",
          "kind": "spend",
          "notes": "lunch",
          "payload": {"value": 40, "notes": "lunch"}
        }
        """

        try q.write { db in
            let row = try InstrumentRegistry.dispatchApply(
                instrumentID: "i1",
                eventJSON: envelope,
                in: db,
                now: ISO8601DateFormatter().date(from: "2026-05-17T12:00:00Z")!
            )
            XCTAssertEqual(row.kindID, "bounded_budget")
        }

        // Verify state_json was updated.
        try q.read { db in
            let json = try String.fetchOne(db, sql: "SELECT state_json FROM instruments WHERE instrument_id = 'i1'")!
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let state = try dec.decode(BoundedBudget.State.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(state.periodTotal, 40)
            XCTAssertEqual(state.remaining, 60)
        }
    }

    func test_dispatchApply_unknownKind_throwsTypedError() throws {
        let q = try makeTempDB()
        let now = Date()
        try q.write { db in
            try db.execute(
                sql: """
                    INSERT INTO instruments
                    (instrument_id, domain, kind, name, definition_json, state_json,
                     state_version, created_at, last_updated_at)
                    VALUES ('i2', 'x', 'nonexistent_kind', 'X', '{}', '{}', 1, ?, ?)
                """,
                arguments: [Int64(now.timeIntervalSince1970 * 1000), Int64(now.timeIntervalSince1970 * 1000)]
            )
        }
        try q.write { db in
            XCTAssertThrowsError(try InstrumentRegistry.dispatchApply(
                instrumentID: "i2",
                eventJSON: "{}",
                in: db,
                now: now
            )) { error in
                guard case InstrumentRegistryError.unknownKind = error else {
                    XCTFail("expected unknownKind, got \(error)")
                    return
                }
            }
        }
    }

    func test_dispatchApply_instrumentNotFound_throws() throws {
        let q = try makeTempDB()
        try q.write { db in
            XCTAssertThrowsError(try InstrumentRegistry.dispatchApply(
                instrumentID: "missing",
                eventJSON: "{}",
                in: db,
                now: Date()
            )) { error in
                guard case InstrumentRegistryError.instrumentNotFound = error else {
                    XCTFail("expected instrumentNotFound, got \(error)")
                    return
                }
            }
        }
    }
}
