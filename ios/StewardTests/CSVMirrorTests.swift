//
//  CSVMirrorTests.swift
//  StewardTests
//
//  Track F DoD coverage:
//  1. CSV writer round-trips a RunningAccumulator instrument
//     (write data.csv → read → state matches).
//  2. Union-merge conflict resolution: per-row_id cell winners by mtime,
//     disagreeing cells emit `requires_user_attention=true` corrections,
//     runner-up rows are preserved (not dropped). Pure-function unit test
//     against `mergeConflictVersions` since NSFileVersion conflicts can't
//     be synthesized in a non-iCloud test sandbox.
//  3. state.csv is NEVER read during reconciliation.
//  4. Old-value resolution + no-op suppression: a repeat correction of the
//     same value to the same `(row_id, cell)` is suppressed.
//  5. ManualCorrection payload uses snake_case keys per spec §1.4 step 3
//     (so Pod B reading payload_json sees `row_id`, `cell_name`, etc.).
//

import XCTest
import GRDB
@testable import Steward

@MainActor
final class CSVMirrorTests: XCTestCase {

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
        state: String = #"{"today_total":0,"seven_day_avg":0,"thirty_day_avg":0}"#
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

    // Register the stub coder fresh per test so the registry doesn't leak
    // between tests (it's a shared actor).
    private func registerStubCoder() async {
        await InstrumentCSVCoderRegistry.shared.reset()
        await InstrumentCSVCoderRegistry.shared.register(
            kindID: StubRunningAccumulatorCoder.kindID,
            coder: StubRunningAccumulatorCoder.make()
        )
    }

    // MARK: - Round-trip

    func test_roundTrip_writesAndReadsDataCSV() async throws {
        let dir = tempDir()
        let paths = try CSVMirrorPaths.resolve(.directory(dir))
        let provider = try await provider(in: dir)
        await registerStubCoder()
        let watcher = CSVMirrorWatcher(paths: paths, provider: provider)

        try await insertInstrument(provider: provider, id: "inst-1")
        let dataURL = try await watcher.ensureInstrumentFile(instrumentID: "inst-1")

        // File exists with header + reserved columns.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataURL.path))
        let raw = try String(contentsOf: dataURL, encoding: .utf8)
        let table = try CSVTable.parse(raw)
        XCTAssertTrue(table.header.contains("__row_id"))
        XCTAssertTrue(table.header.contains("__steward_version"))
        XCTAssertTrue(table.header.contains("__last_synced_at"))
        XCTAssertTrue(table.header.contains("value"))

        // Append a user row, reconcile → expect one log_entry event.
        let newRow = CSVTable.Row(cells: [
            "", // __row_id empty → treated as new entry
            "",
            "",
            "1716000000000",
            "42",
            "added in Numbers"
        ])
        let edited = CSVTable(header: table.header, rows: [newRow])
        try edited.serialize().write(to: dataURL, atomically: true, encoding: .utf8)

        let emitted = try await watcher.reconcile(instrumentID: "inst-1")
        XCTAssertEqual(emitted, 1, "Expected exactly one log_entry from new row")

        let db = try await provider.database()
        try await db.read { dbase in
            let count = try Int.fetchOne(
                dbase,
                sql: """
                    SELECT COUNT(*) FROM events
                    WHERE instrument_id = ? AND kind = 'log_entry' AND source = 'sheets_edit'
                """,
                arguments: ["inst-1"]
            ) ?? 0
            XCTAssertEqual(count, 1)
        }

        // State.csv must exist after reconcile (write-only output).
        let stateURL = try paths.instrumentStateURL(domain: "health", name: "movement_minutes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path),
                      "state.csv should be regenerated after reconcile")
    }

    // MARK: - Hard reject #13: state.csv never re-ingested

    func test_stateCSV_isNeverReadDuringReconciliation() async throws {
        let dir = tempDir()
        let paths = try CSVMirrorPaths.resolve(.directory(dir))
        let provider = try await provider(in: dir)
        await registerStubCoder()
        let watcher = CSVMirrorWatcher(paths: paths, provider: provider)

        try await insertInstrument(provider: provider, id: "inst-1")
        _ = try await watcher.ensureInstrumentFile(instrumentID: "inst-1")

        // Tamper with state.csv aggressively.
        let stateURL = try paths.instrumentStateURL(domain: "health", name: "movement_minutes")
        let evilState = CSVTable(
            header: ["__row_id", "value", "notes"],
            rows: [
                CSVTable.Row(cells: ["", "999", "should not appear in events"]),
                CSVTable.Row(cells: ["", "1000", "also should not appear"])
            ]
        )
        try evilState.serialize().write(to: stateURL, atomically: true, encoding: .utf8)

        // Empty data.csv so any emitted events MUST have come from state.csv.
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
    //
    // Synthesizing real NSFileVersion conflicts requires iCloud — not
    // possible in a test sandbox. We test the merge algorithm in isolation
    // against `CSVMirrorWatcher.mergeConflictVersions`.

    func test_conflictMerge_unionsRowIDsAcrossVersions() throws {
        let header = ["__row_id", "value", "notes"]
        let older = CSVTable(header: header, rows: [
            CSVTable.Row(cells: ["ROW-A", "5", "older A"]),
            CSVTable.Row(cells: ["ROW-B", "10", "only in older"])
        ])
        let newer = CSVTable(header: header, rows: [
            CSVTable.Row(cells: ["ROW-A", "7", "newer A"]),
            CSVTable.Row(cells: ["ROW-C", "99", "only in newer"])
        ])
        let (merged, disagreements) = CSVMirrorWatcher.mergeConflictVersions([
            (older, Date(timeIntervalSince1970: 100)),
            (newer, Date(timeIntervalSince1970: 200))
        ])
        let rowIDs = Set(merged.rows.compactMap { $0.value(forColumn: "__row_id", in: merged.header) })
        XCTAssertEqual(rowIDs, ["ROW-A", "ROW-B", "ROW-C"],
                       "union-merge must preserve runner-up rows (ROW-B), not drop them")

        // ROW-A disagreed on value + notes → 2 corrections, both flagged.
        XCTAssertEqual(disagreements.count, 2)
        for d in disagreements {
            XCTAssertEqual(d.rowID, "ROW-A")
            XCTAssertTrue(d.requiresUserAttention, "conflict-merge corrections must require user attention")
        }
        let cells = Set(disagreements.map(\.cellName))
        XCTAssertEqual(cells, ["value", "notes"])
        // Winner cell values come from newer version (mtime 200 > 100).
        let aRow = merged.rows.first { $0.value(forColumn: "__row_id", in: merged.header) == "ROW-A" }
        XCTAssertEqual(aRow?.value(forColumn: "value", in: merged.header), "7")
        XCTAssertEqual(aRow?.value(forColumn: "notes", in: merged.header), "newer A")
    }

    func test_conflictMerge_agreementProducesNoDisagreements() throws {
        let header = ["__row_id", "value"]
        let v1 = CSVTable(header: header, rows: [CSVTable.Row(cells: ["X", "42"])])
        let v2 = CSVTable(header: header, rows: [CSVTable.Row(cells: ["X", "42"])])
        let (_, disagreements) = CSVMirrorWatcher.mergeConflictVersions([
            (v1, Date(timeIntervalSince1970: 100)),
            (v2, Date(timeIntervalSince1970: 200))
        ])
        XCTAssertTrue(disagreements.isEmpty)
    }

    // MARK: - ManualCorrection payload shape (spec §1.4 step 3)

    func test_manualCorrectionPayload_usesSnakeCaseKeys() throws {
        let c = ManualCorrection(
            rowID: "ROW-A",
            cellName: "value",
            oldValue: "5",
            newValue: "7",
            originalEventID: "EVT-1",
            requiresUserAttention: true
        )
        let data = try JSONEncoder().encode(c)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"row_id\""), "expected snake_case row_id: \(json)")
        XCTAssertTrue(json.contains("\"cell_name\""), "expected snake_case cell_name: \(json)")
        XCTAssertTrue(json.contains("\"old_value\""), "expected snake_case old_value: \(json)")
        XCTAssertTrue(json.contains("\"new_value\""), "expected snake_case new_value: \(json)")
        XCTAssertTrue(json.contains("\"original_event_id\""), "expected snake_case original_event_id: \(json)")
        XCTAssertTrue(json.contains("\"requires_user_attention\""),
                      "expected snake_case requires_user_attention: \(json)")
        XCTAssertFalse(json.contains("\"columnName\""))
        XCTAssertFalse(json.contains("\"rowID\""))
    }

    // MARK: - Old-value resolution + no-op suppression

    func test_repeatedSameValueEdit_isSuppressed() async throws {
        let dir = tempDir()
        let paths = try CSVMirrorPaths.resolve(.directory(dir))
        let provider = try await provider(in: dir)
        await registerStubCoder()
        let watcher = CSVMirrorWatcher(paths: paths, provider: provider)

        try await insertInstrument(provider: provider, id: "inst-3", name: "water_oz")
        let dataURL = try await watcher.ensureInstrumentFile(instrumentID: "inst-3")
        let initial = try CSVTable.parse(String(contentsOf: dataURL, encoding: .utf8))

        // First edit: set ROW-X value="8".
        let firstEdit = CSVTable(header: initial.header, rows: [
            CSVTable.Row(cells: ["ROW-X", "1", "0", "1716000000000", "8", "first edit"])
        ])
        try firstEdit.serialize().write(to: dataURL, atomically: true, encoding: .utf8)
        let firstEmitted = try await watcher.reconcile(instrumentID: "inst-3")
        // Stub coder reports value+notes corrections; both are new → 2 events.
        XCTAssertGreaterThanOrEqual(firstEmitted, 1)

        // Reconcile again with the SAME file → every cell matches the prior
        // write → no-op suppression should emit 0 corrections.
        let secondEmitted = try await watcher.reconcile(instrumentID: "inst-3")
        XCTAssertEqual(secondEmitted, 0,
                       "second reconcile of unchanged data.csv must emit zero corrections")
    }

    func test_oldValueAndOriginalEventID_populatedFromEvents() async throws {
        let dir = tempDir()
        let paths = try CSVMirrorPaths.resolve(.directory(dir))
        let provider = try await provider(in: dir)
        await registerStubCoder()
        let watcher = CSVMirrorWatcher(paths: paths, provider: provider)

        try await insertInstrument(provider: provider, id: "inst-4", name: "minutes_outside")
        let dataURL = try await watcher.ensureInstrumentFile(instrumentID: "inst-4")
        let initial = try CSVTable.parse(String(contentsOf: dataURL, encoding: .utf8))

        // First edit establishes prior value "8".
        let first = CSVTable(header: initial.header, rows: [
            CSVTable.Row(cells: ["ROW-Z", "1", "0", "1716000000000", "8", "n1"])
        ])
        try first.serialize().write(to: dataURL, atomically: true, encoding: .utf8)
        _ = try await watcher.reconcile(instrumentID: "inst-4")

        // Capture the first event's id for the assertion.
        let db = try await provider.database()
        let firstValueEventID = try await db.read { dbase -> String in
            try String.fetchOne(
                dbase,
                sql: """
                    SELECT event_id FROM events
                    WHERE instrument_id = ? AND kind = 'manual_correction'
                      AND payload_json LIKE '%"cell_name":"value"%'
                    ORDER BY created_at DESC LIMIT 1
                """,
                arguments: ["inst-4"]
            ) ?? ""
        }
        XCTAssertFalse(firstValueEventID.isEmpty)

        // Second edit changes value to "12".
        let second = CSVTable(header: initial.header, rows: [
            CSVTable.Row(cells: ["ROW-Z", "1", "0", "1716000000000", "12", "n1"])
        ])
        try second.serialize().write(to: dataURL, atomically: true, encoding: .utf8)
        let emitted = try await watcher.reconcile(instrumentID: "inst-4")
        XCTAssertGreaterThanOrEqual(emitted, 1)

        // Latest correction's payload should carry old_value="8" +
        // original_event_id=<firstValueEventID>.
        try await db.read { dbase in
            let payload = try String.fetchOne(
                dbase,
                sql: """
                    SELECT payload_json FROM events
                    WHERE instrument_id = ? AND kind = 'manual_correction'
                      AND payload_json LIKE '%"cell_name":"value"%'
                    ORDER BY created_at DESC LIMIT 1
                """,
                arguments: ["inst-4"]
            ) ?? ""
            XCTAssertTrue(payload.contains("\"old_value\":\"8\""),
                          "expected old_value=8 in latest payload, got: \(payload)")
            XCTAssertTrue(payload.contains("\"new_value\":\"12\""),
                          "expected new_value=12 in latest payload, got: \(payload)")
            XCTAssertTrue(payload.contains("\"original_event_id\":\"\(firstValueEventID)\""),
                          "expected original_event_id=\(firstValueEventID) in latest payload, got: \(payload)")
        }
    }

    // MARK: - Tools sanity

    func test_csvMirrorTools_enqueueAndComplete() async throws {
        let dir = tempDir()
        let paths = try CSVMirrorPaths.resolve(.directory(dir))
        let provider = try await provider(in: dir)
        await registerStubCoder()
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

    func test_pathTraversal_rejectsDotDot() {
        let dir = tempDir()
        let paths = try? CSVMirrorPaths.resolve(.directory(dir))
        XCTAssertNotNil(paths)
        XCTAssertThrowsError(try paths!.instrumentDataURL(domain: "health", name: ".."))
        XCTAssertThrowsError(try paths!.instrumentDataURL(domain: "health", name: "."))
        XCTAssertThrowsError(try paths!.instrumentDataURL(domain: "..", name: "movement_minutes"))
        // Embedded consecutive dots also rejected (omittingEmptySubsequences:false).
        XCTAssertThrowsError(try paths!.instrumentDataURL(domain: "health", name: "a..b"))
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
        XCTAssertEqual(table.rows[0].cells, ["hello, world", "line1\nline2", "plain"])

        let serialized = table.serialize()
        let reparsed = try CSVTable.parse(serialized)
        XCTAssertEqual(reparsed.rows[0].cells, table.rows[0].cells)
    }
}
