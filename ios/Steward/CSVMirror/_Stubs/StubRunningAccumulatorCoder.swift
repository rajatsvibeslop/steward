//
//  StubRunningAccumulatorCoder.swift
//  Steward — Track F
//
//  REMOVE AT MERGE — Pod C provides canonical
//  ----------------------------------------------
//  This file exists only so Track F can ship and demo the CSV mirror against
//  the simplest instrument kind before Track C's `InstrumentKind` protocol
//  (addendum §1.2) lands. When Pod C merges, the merger MUST:
//
//   1. Delete this file (and its sibling `ULIDFactoryStub.swift`).
//   2. Register the canonical RunningAccumulator coder from Pod C via
//      `await InstrumentCSVCoderRegistry.shared.register(kindID:coder:)` in
//      Pod C's boot path.
//   3. Remove the `await TrackFBootstrap.registerStubCoders()` call in
//      `StewardApp.AppBootstrap.start()` (the call site is marked with the
//      same `REMOVE AT MERGE` comment).
//
//  Track F production code never references this type directly — registration
//  is the only seam, so deletion is mechanical.
//

import Foundation

enum StubRunningAccumulatorCoder {
    static let kindID = "running_accumulator"

    static let dataColumns = [
        CSVTable.Reserved.rowID,
        CSVTable.Reserved.stewardVersion,
        CSVTable.Reserved.lastSyncedAt,
        "occurred_at",
        "value",
        "notes"
    ]

    static let stateColumns = ["metric", "value"]

    /// Build the bridging coder for registration at boot.
    static func make() -> InstrumentCSVCoder {
        InstrumentCSVCoder(
            renderData: renderData(stateJSON:definitionJSON:recentEventsJSON:),
            renderState: renderState(stateJSON:definitionJSON:),
            initialDataColumns: dataColumns,
            parseOverride: parseOverride(_:currentStateJSON:definitionJSON:)
        )
    }

    // MARK: - renderData

    private static func renderData(
        stateJSON: String,
        definitionJSON: String,
        recentEventsJSON: [String]
    ) throws -> CSVTable {
        _ = stateJSON
        _ = definitionJSON
        let decoder = JSONDecoder()
        var rows: [CSVTable.Row] = []
        for jsonString in recentEventsJSON {
            guard let data = jsonString.data(using: .utf8) else { continue }
            let evt = try decoder.decode(StubRunningEvent.self, from: data)
            rows.append(CSVTable.Row(cells: [
                evt.event_id,
                String(evt.steward_version ?? 1),
                String(evt.last_synced_at ?? Int64(Date().timeIntervalSince1970 * 1000)),
                String(evt.occurred_at),
                String(evt.value),
                evt.notes ?? ""
            ]))
        }
        return CSVTable(header: dataColumns, rows: rows)
    }

    // MARK: - renderState

    private static func renderState(stateJSON: String, definitionJSON: String) throws -> CSVTable {
        _ = definitionJSON
        struct State: Decodable {
            let today_total: Double?
            let seven_day_avg: Double?
            let thirty_day_avg: Double?
            let last_event_at: Int64?
        }
        guard let data = stateJSON.data(using: .utf8) else {
            return CSVTable(header: stateColumns, rows: [])
        }
        let s = (try? JSONDecoder().decode(State.self, from: data)) ?? .init(
            today_total: nil, seven_day_avg: nil, thirty_day_avg: nil, last_event_at: nil
        )
        let rows: [CSVTable.Row] = [
            CSVTable.Row(cells: ["today_total", s.today_total.map { String($0) } ?? ""]),
            CSVTable.Row(cells: ["seven_day_avg", s.seven_day_avg.map { String($0) } ?? ""]),
            CSVTable.Row(cells: ["thirty_day_avg", s.thirty_day_avg.map { String($0) } ?? ""]),
            CSVTable.Row(cells: ["last_event_at", s.last_event_at.map { String($0) } ?? ""])
        ]
        return CSVTable(header: stateColumns, rows: rows)
    }

    // MARK: - parseOverride

    private static func parseOverride(
        _ table: CSVTable,
        currentStateJSON: String,
        definitionJSON: String
    ) throws -> CSVOverrideResult {
        _ = currentStateJSON
        _ = definitionJSON
        guard table.header.contains(CSVTable.Reserved.rowID) else {
            throw CSVTableError.missingRequiredColumn(CSVTable.Reserved.rowID)
        }
        let (keyed, unkeyed) = table.partitionedByRowID()

        // For the stub, report every value/notes cell as a candidate
        // correction. The watcher resolves `old_value` + `original_event_id`
        // by querying the events table and suppresses no-op corrections.
        var corrections: [ManualCorrection] = []
        for (rowID, row) in keyed {
            for col in ["value", "notes"] {
                if let newValue = row.value(forColumn: col, in: table.header) {
                    corrections.append(ManualCorrection(
                        rowID: rowID,
                        cellName: col,
                        oldValue: nil,           // resolved by watcher
                        newValue: newValue,
                        originalEventID: nil     // resolved by watcher
                    ))
                }
            }
        }
        var newEntries: [ManualLogEntry] = []
        for row in unkeyed {
            var cells: [String: String] = [:]
            for (i, name) in table.header.enumerated() where !CSVTable.Reserved.all.contains(name) {
                guard i < row.cells.count else { continue }
                cells[name] = row.cells[i]
            }
            newEntries.append(ManualLogEntry(
                assignedRowID: ULIDFactory.make(),
                cells: cells
            ))
        }
        return CSVOverrideResult(corrections: corrections, newEntries: newEntries)
    }

    private struct StubRunningEvent: Decodable {
        let event_id: String
        let occurred_at: Int64
        let value: Double
        let notes: String?
        let steward_version: Int?
        let last_synced_at: Int64?
    }
}
