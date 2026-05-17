//
//  InstrumentCSVCoder.swift
//  Steward — Track F
//
//  Bridging layer between Track C's `InstrumentKind` protocol (addendum §1.2)
//  and the CSV mirror in Track F. Per-kind static `renderCSV`, `parseCSVOverride`,
//  `renderStateCSV`, and `initialDataColumns` are wrapped in a `Coder` value and
//  registered by kind id; the watcher dispatches every operation through the
//  registry so there is no string-keyed `if snap.kind == ...` branch anywhere
//  in production code (hard reject #9).
//
//  Track C-owned concrete coders live under `Steward/Instruments/` once that
//  pod lands. Until then a stub lives under `CSVMirror/_Stubs/` — see
//  `_Stubs/StubRunningAccumulatorCoder.swift`. Track F production code never
//  imports the stub by type; it only registers it at boot under a marker that
//  Integration deletes when Pod C merges.
//

import Foundation

/// Diff result for one cell, emitted as a `manual_correction` event payload
/// (addendum §1.4 step 3). On-disk shape uses snake_case so Pod B reading
/// `payload_json` sees the column names spec calls out (`row_id`, `cell_name`,
/// `old_value`, `new_value`, `original_event_id`).
struct ManualCorrection: Codable, Sendable, Equatable {
    let rowID: String
    let cellName: String
    /// Most recent prior value Steward wrote for this `(row_id, cell_name)`,
    /// resolved at emit time from the `events` table. `nil` when there is no
    /// prior — i.e. the row was added by Steward and the user is the first to
    /// edit this cell.
    let oldValue: String?
    let newValue: String
    /// `event_id` of the manual_correction / log_entry / instrument_update that
    /// last wrote this cell. `nil` when no prior write exists.
    let originalEventID: String?
    /// Set when this correction came from a conflict-resolution merge across
    /// NSFileVersions; surfaces the row to the user in the chat next-turn
    /// context. Per addendum §1.4 step 1.
    var requiresUserAttention: Bool = false

    enum CodingKeys: String, CodingKey {
        case rowID = "row_id"
        case cellName = "cell_name"
        case oldValue = "old_value"
        case newValue = "new_value"
        case originalEventID = "original_event_id"
        case requiresUserAttention = "requires_user_attention"
    }
}

/// New row from the CSV that has no matching `__row_id` in the events table.
/// Emitted as `log_entry` events with `source='sheets_edit'` per §1.4 step 4.
struct ManualLogEntry: Codable, Sendable, Equatable {
    let assignedRowID: String
    let cells: [String: String]

    enum CodingKeys: String, CodingKey {
        case assignedRowID = "assigned_row_id"
        case cells
    }
}

/// The full set of operations a kind must provide so Track F can render and
/// reconcile its CSV. Track C's `InstrumentKind` static funcs map 1:1 onto
/// these closures via `InstrumentCSVCoder(kind:)` once their protocol lands.
struct InstrumentCSVCoder: Sendable {
    /// Render the current state + recent events into the editable data.csv
    /// table. The table MUST include the reserved columns (`__row_id`,
    /// `__steward_version`, `__last_synced_at`) so reconciliation can diff
    /// cell-by-cell. `recentEventsJSON` is each event's `payload_json` blob.
    let renderData: @Sendable (_ stateJSON: String, _ definitionJSON: String, _ recentEventsJSON: [String]) throws -> CSVTable

    /// Render the write-only state.csv snapshot from instrument state.
    let renderState: @Sendable (_ stateJSON: String, _ definitionJSON: String) throws -> CSVTable

    /// Columns for the initial empty data.csv (before any events exist).
    /// Reserved columns must appear in this list.
    let initialDataColumns: [String]

    /// Compute corrections + new entries from a user-edited table. Returns
    /// what changed; caller (`CSVMirrorWatcher`) owns event emission, state
    /// update, and `old_value` / `original_event_id` resolution against the
    /// `events` table.
    let parseOverride: @Sendable (_ table: CSVTable, _ currentStateJSON: String, _ definitionJSON: String) throws -> CSVOverrideResult
}

struct CSVOverrideResult: Sendable, Equatable {
    var corrections: [ManualCorrection]
    var newEntries: [ManualLogEntry]
}

/// Process-wide registry mapping `instruments.kind` strings to a coder. Track
/// C's `@main` boot calls `register(kindID:coder:)` for each of the 7 built-in
/// kinds; Track F's `CSVMirrorWatcher` looks them up by the row's `kind`
/// column.
actor InstrumentCSVCoderRegistry {
    static let shared = InstrumentCSVCoderRegistry()

    private var coders: [String: InstrumentCSVCoder] = [:]

    func register(kindID: String, coder: InstrumentCSVCoder) {
        coders[kindID] = coder
    }

    func coder(for kindID: String) -> InstrumentCSVCoder? {
        coders[kindID]
    }

    /// Test seam — wipes registrations between unit tests. Tests register
    /// stub coders per test.
    func reset() {
        coders.removeAll()
    }
}
