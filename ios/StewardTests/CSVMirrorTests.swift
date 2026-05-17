//
//  CSVMirrorTests.swift
//  StewardTests
//
//  Track F DoD coverage against Pod C's canonical InstrumentKind types:
//  1. CSV writer round-trips for a real Pod C kind (RunningAccumulator) —
//     ensureInstrumentFile produces a file with `__row_id`, `__steward_version`,
//     `__last_synced_at` headers; reconcile on unchanged contents is a no-op.
//  2. Conflict union-merge: per-row_id cell winners by mtime, disagreeing
//     cells emit ManualCorrection entries flagged via the conflict reason
//     prefix, runner-up rows preserved (pure-function test of
//     mergeConflictVersions).
//  3. state.csv is NEVER read during reconciliation.
//  4. Path traversal guard rejects `..` / `.` / `a..b`.
//  5. ManualCorrection payload uses Pod C's snake_case (`row_id`, `cell`,
//     `old_value`, `new_value`, `correction_id`, `applied_at`, `reason`).
//
//  Note: parseCSVOverride returns [] for all kinds in v1 per impl-track-c's
//  accepted v1.1 deferral, so the reconcile loop emits zero events on the
//  happy path. Tests assert this expected behavior.
//

import XCTest
import GRDB
@testable import Steward

@MainActor
final class CSVMirrorTests: XCTestCase {

    override func setUp() async throws {
        // Pod C's registry needs to be live for any reconcile/render call.
        InstrumentRegistry._resetForTesting()
        InstrumentRegistry.bootstrapAll()
    }

    // MARK: - Helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-csv-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func provider(in baseDir: URL) async throws -> DatabaseProvider {
        let dbURL = baseDir.appendingPathComponent("steward.sqlite")
        let p = DatabaseProvider(location: .file(dbURL))
        _ = try await p.database()
        return p
    }

    private func insertInstrument(
        provider: DatabaseProvider,
        id: String,
        kind: String = "running_accumulator",
        domain: String = "health",
        name: String = "movement_minutes",
        definition: String = #"{"unit":"min","daily_target":30,"capture_prompt":"how many minutes?"}"#,
        // Matches Pod C's `RunningAccumulator.State` shape — includes
        // `window_events` so JSONDecoder.decode succeeds in the renderCSV
        // bridge. Generated via `RunningAccumulator.initialState(definition:now:)`.
        state: String = #"{"window_events":[],"today_total":0,"seven_day_avg":0,"thirty_day_avg":0,"last_event_at":null}"#
    ) async throws {
        let db = try await provider.database()
        try await db.write { dbase in
            try dbase.execute(sql: """
                INSERT INTO instruments (
                    instrument_id, domain, kind, name,
                    definition_json, state_json, state_version,
                    created_at, last_updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                """, arguments: [id, domain, kind, name, definition, state, 1, 1])
        }
    }

    private func registerCoders() async {
        await InstrumentCSVCoderRegistry.shared.reset()
        await TrackFBootstrap.registerKindCoders()
    }

    // MARK: - Round-trip

    func test_roundTrip_writesDataCSVWithReservedHeaders() async throws {
        let dir = tempDir()
        let paths = try CSVMirrorPaths.resolve(.directory(dir))
        let provider = try await provider(in: dir)
        await registerCoders()
        let watcher = CSVMirrorWatcher(paths: paths, provider: provider)

        try await insertInstrument(provider: provider, id: "inst-1")
        let dataURL = try await watcher.ensureInstrumentFile(instrumentID: "inst-1")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dataURL.path))
        let raw = try String(contentsOf: dataURL, encoding: .utf8)
        let table = try CSVTable.parse(raw)
        XCTAssertTrue(table.header.contains(CSVReserved.rowID))
        XCTAssertTrue(table.header.contains(CSVReserved.stewardVersion))
        XCTAssertTrue(table.header.contains(CSVReserved.lastSyncedAt))

        // Reconcile on an unchanged file should be a no-op (parseCSVOverride
        // returns [] for v1).
        let emitted = try await watcher.reconcile(instrumentID: "inst-1")
        XCTAssertEqual(emitted, 0, "v1 parseCSVOverride returns []; expected no events on unchanged data.csv")

        let stateURL = try paths.instrumentStateURL(domain: "health", name: "movement_minutes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path),
                      "state.csv should be regenerated after reconcile")
    }

    // MARK: - Hard reject #13: state.csv never re-ingested

    func test_stateCSV_isNeverReadDuringReconciliation() async throws {
        let dir = tempDir()
        let paths = try CSVMirrorPaths.resolve(.directory(dir))
        let provider = try await provider(in: dir)
        await registerCoders()
        let watcher = CSVMirrorWatcher(paths: paths, provider: provider)

        try await insertInstrument(provider: provider, id: "inst-1")
        _ = try await watcher.ensureInstrumentFile(instrumentID: "inst-1")

        let stateURL = try paths.instrumentStateURL(domain: "health", name: "movement_minutes")
        let evilState = CSVTable(
            header: ["__row_id", "value", "notes"],
            rows: [
                ["", "999", "should not appear in events"],
                ["", "1000", "also should not appear"]
            ]
        )
        try evilState.serialize().write(to: stateURL, atomically: true, encoding: .utf8)

        let dataURL = try paths.instrumentDataURL(domain: "health", name: "movement_minutes")
        let dataText = try String(contentsOf: dataURL, encoding: .utf8)
        let table = try CSVTable.parse(dataText)
        let emptyAgain = CSVTable(header: table.header, rows: [])
        try emptyAgain.serialize().write(to: dataURL, atomically: true, encoding: .utf8)

        let emitted = try await watcher.reconcile(instrumentID: "inst-1")
        XCTAssertEqual(emitted, 0, "state.csv must never be ingested — got \(emitted) events")

        let db = try await provider.database()
        try await db.read { dbase in
            let leaks = try Int.fetchOne(
                dbase,
                sql: """
                    SELECT COUNT(*) FROM events
                    WHERE instrument_id = ?
                      AND payload_json LIKE '%should not appear%'
                """,
                arguments: ["inst-1"]
            ) ?? 0
            XCTAssertEqual(leaks, 0, "state.csv contents leaked into events table")
        }
    }

    // MARK: - Conflict union-merge (pure function)

    func test_conflictMerge_unionsRowIDsAcrossVersions() throws {
        let header = ["__row_id", "value", "notes"]
        let older = CSVTable(header: header, rows: [
            ["ROW-A", "5", "older A"],
            ["ROW-B", "10", "only in older"]
        ])
        let newer = CSVTable(header: header, rows: [
            ["ROW-A", "7", "newer A"],
            ["ROW-C", "99", "only in newer"]
        ])
        let (merged, disagreements) = CSVMirrorWatcher.mergeConflictVersions([
            (older, Date(timeIntervalSince1970: 100)),
            (newer, Date(timeIntervalSince1970: 200))
        ])
        let rowIDs = Set(merged.rows.compactMap {
            CSVDiff.cellAt(row: $0, header: merged.header, column: "__row_id")
        })
        XCTAssertEqual(rowIDs, ["ROW-A", "ROW-B", "ROW-C"],
                       "union-merge must preserve runner-up rows (ROW-B), not drop them")

        // ROW-A disagreed on value + notes → 2 corrections, both flagged via
        // the conflict reason prefix.
        XCTAssertEqual(disagreements.count, 2)
        for d in disagreements {
            XCTAssertEqual(d.rowID, "ROW-A")
            XCTAssertTrue(d.reason.hasPrefix(CSVMirrorConflictReasonPrefix),
                          "conflict-merge corrections must carry the user-attention reason prefix: \(d.reason)")
        }
        let cells = Set(disagreements.compactMap(\.cell))
        XCTAssertEqual(cells, ["value", "notes"])

        // Winner cell values come from newer version (mtime 200 > 100).
        let aRow = merged.rows.first { CSVDiff.cellAt(row: $0, header: merged.header, column: "__row_id") == "ROW-A" }
        XCTAssertEqual(CSVDiff.cellAt(row: aRow ?? [], header: merged.header, column: "value"), "7")
        XCTAssertEqual(CSVDiff.cellAt(row: aRow ?? [], header: merged.header, column: "notes"), "newer A")
    }

    func test_conflictMerge_agreementProducesNoDisagreements() throws {
        let header = ["__row_id", "value"]
        let v1 = CSVTable(header: header, rows: [["X", "42"]])
        let v2 = CSVTable(header: header, rows: [["X", "42"]])
        let (_, disagreements) = CSVMirrorWatcher.mergeConflictVersions([
            (v1, Date(timeIntervalSince1970: 100)),
            (v2, Date(timeIntervalSince1970: 200))
        ])
        XCTAssertTrue(disagreements.isEmpty)
    }

    // MARK: - ManualCorrection payload shape (Pod C canonical types)

    func test_manualCorrectionPayload_usesSnakeCaseKeys() throws {
        let c = ManualCorrection(
            correctionID: "CORR-1",
            rowID: "ROW-A",
            cell: "value",
            oldValue: "5",
            newValue: "7",
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            reason: "user edit"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(c)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"correction_id\""), "expected snake_case correction_id: \(json)")
        XCTAssertTrue(json.contains("\"row_id\""), "expected snake_case row_id: \(json)")
        XCTAssertTrue(json.contains("\"old_value\""), "expected snake_case old_value: \(json)")
        XCTAssertTrue(json.contains("\"new_value\""), "expected snake_case new_value: \(json)")
        XCTAssertTrue(json.contains("\"applied_at\""), "expected snake_case applied_at: \(json)")
        XCTAssertTrue(json.contains("\"reason\""), "expected reason field: \(json)")
    }

    // MARK: - Tools sanity

    func test_csvMirrorTools_enqueueAndComplete() async throws {
        let dir = tempDir()
        let paths = try CSVMirrorPaths.resolve(.directory(dir))
        let provider = try await provider(in: dir)
        await registerCoders()
        let watcher = CSVMirrorWatcher(paths: paths, provider: provider)

        let tools = CSVMirrorTools(
            provider: provider,
            settings: SettingsStore(provider: provider)
        )
        await tools.configure(watcher: watcher)

        try await insertInstrument(provider: provider, id: "inst-2", name: "water_oz")

        _ = try await tools.ensureInstrumentFile(instrumentID: "inst-2")
        let processed = try await tools.syncNow()
        XCTAssertGreaterThanOrEqual(processed, 1, "syncNow should drain at least the enqueued write")

        let db = try await provider.database()
        try await db.read { dbase in
            let pending = try Int.fetchOne(
                dbase,
                sql: "SELECT COUNT(*) FROM sync_queue WHERE target='csv_mirror' AND completed_at IS NULL"
            ) ?? 0
            XCTAssertEqual(pending, 0, "All enqueued rows should complete after syncNow")
        }
    }

    // MARK: - Path traversal guard

    func test_pathTraversal_rejectsDotDot() throws {
        let dir = tempDir()
        let paths = try CSVMirrorPaths.resolve(.directory(dir))
        XCTAssertThrowsError(try paths.instrumentDataURL(domain: "health", name: ".."))
        XCTAssertThrowsError(try paths.instrumentDataURL(domain: "health", name: "."))
        XCTAssertThrowsError(try paths.instrumentDataURL(domain: "..", name: "movement_minutes"))
        XCTAssertThrowsError(try paths.instrumentDataURL(domain: "health", name: "a..b"))
    }

    // MARK: - Coder registration sanity

    func test_allSevenKindsRegisterCoders() async throws {
        await registerCoders()
        let kinds = [
            "running_accumulator",
            "bounded_budget",
            "rolling_average",
            "countdown_commitment",
            "weekly_evidence_log",
            "checklist",
            "bounded_window"
        ]
        for kind in kinds {
            let c = await InstrumentCSVCoderRegistry.shared.coder(for: kind)
            XCTAssertNotNil(c, "registerKindCoders should register coder for '\(kind)'")
        }
    }

    // MARK: - CSVTable parser sanity (RFC 4180 quoting)

    func test_csvTable_handlesQuotedCommasAndEmbeddedNewlines() throws {
        let raw = """
        a,b,c\r
        "hello, world","line1\nline2","plain"\r
        """
        let table = try CSVTable.parse(raw)
        XCTAssertEqual(table.header, ["a", "b", "c"])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0], ["hello, world", "line1\nline2", "plain"])

        let serialized = table.serialize()
        let reparsed = try CSVTable.parse(serialized)
        XCTAssertEqual(reparsed.rows[0], table.rows[0])
    }
}
