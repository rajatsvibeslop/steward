//
//  WeeklyEvidenceLog.swift
//  Steward
//
//  Spec §6: qualitative weekly log. Each week the user logs N entries; on
//  week rollover, the previous week's entries collapse into a summary stub
//  the coordinator can synthesize later. State is text-heavy, not numeric.
//

import Foundation

enum WeeklyEvidenceLog: InstrumentKind {

    // MARK: - Definition

    struct Definition: Codable, Sendable, Equatable {
        var prompt: String
        /// Day-of-week the week starts on, 1=Sun .. 7=Sat per ISO. We default
        /// to 2 (Monday) at the call site; the user can override.
        var weekStartDow: Int

        enum CodingKeys: String, CodingKey {
            case prompt
            case weekStartDow = "week_start_dow"
        }
    }

    // MARK: - State

    struct State: Codable, Sendable, Equatable {
        struct Entry: Codable, Sendable, Equatable {
            let at: Date
            let text: String
        }
        struct WeekSummary: Codable, Sendable, Equatable {
            let weekStart: Date
            let entryCount: Int
            /// Joined-then-truncated headline preview. Full text stays in the
            /// events table for retrieval.
            let preview: String
        }
        var currentWeekStart: Date
        var currentWeekEntries: [Entry]
        /// Bounded tail: last 12 weeks (~quarter).
        var previousWeeksSummaries: [WeekSummary]

        enum CodingKeys: String, CodingKey {
            case currentWeekStart = "current_week_start"
            case currentWeekEntries = "current_week_entries"
            case previousWeeksSummaries = "previous_weeks_summaries"
        }
    }

    // MARK: - EventPayload

    struct EventPayload: Codable, Sendable, Equatable {
        let text: String
    }

    // MARK: - InstrumentKind

    static let id: String = "weekly_evidence_log"
    static let stateVersion: Int = 1

    static func initialState(definition: Definition, now: Date) -> State {
        State(
            currentWeekStart: weekStart(for: now, weekStartDow: definition.weekStartDow),
            currentWeekEntries: [],
            previousWeeksSummaries: []
        )
    }

    static func apply(
        event: InstrumentEvent<EventPayload>,
        to state: State,
        definition: Definition,
        now: Date
    ) throws -> State {
        let evWeekStart = weekStart(for: event.createdAt, weekStartDow: definition.weekStartDow)
        var working = state
        if evWeekStart > state.currentWeekStart {
            // Roll: snapshot the closing week into a summary.
            let summary = State.WeekSummary(
                weekStart: state.currentWeekStart,
                entryCount: state.currentWeekEntries.count,
                preview: previewOf(entries: state.currentWeekEntries)
            )
            let tail = (state.previousWeeksSummaries + [summary]).suffix(12)
            working = State(
                currentWeekStart: evWeekStart,
                currentWeekEntries: [],
                previousWeeksSummaries: Array(tail)
            )
        }
        let entry = State.Entry(at: event.createdAt, text: event.payload.text)
        return State(
            currentWeekStart: working.currentWeekStart,
            currentWeekEntries: working.currentWeekEntries + [entry],
            previousWeeksSummaries: working.previousWeeksSummaries
        )
    }

    static func applyManualCorrection(
        _ correction: ManualCorrection,
        to state: State,
        definition: Definition
    ) throws -> State {
        // CSV correction targets a specific entry's `text` cell. We replace
        // the matching row in `currentWeekEntries` by ordinal index (row_id
        // encodes index for this kind).
        guard let rowID = correction.rowID,
              let prefixRange = rowID.range(of: "entry-"),
              prefixRange.lowerBound == rowID.startIndex,
              let index = Int(rowID[prefixRange.upperBound...]),
              index >= 0, index < state.currentWeekEntries.count else {
            throw InstrumentKindError.unparseableCSV(
                reason: "WeeklyEvidenceLog correction expected rowID 'entry-<index>' within currentWeekEntries, got \(correction.rowID ?? "nil")"
            )
        }
        guard let newText = correction.newValue else {
            throw InstrumentKindError.unparseableCSV(
                reason: "WeeklyEvidenceLog correction expected newValue (text)"
            )
        }
        var entries = state.currentWeekEntries
        entries[index] = State.Entry(at: entries[index].at, text: newText)
        return State(
            currentWeekStart: state.currentWeekStart,
            currentWeekEntries: entries,
            previousWeeksSummaries: state.previousWeeksSummaries
        )
    }

    static func renderCSV(
        state: State,
        definition: Definition,
        recentEvents: [InstrumentEvent<EventPayload>]
    ) -> CSVTable {
        let cols = ["entry_at", "text"]
        let iso = ISO8601DateFormatter()
        let rows: [[String]] = state.currentWeekEntries.enumerated().map { idx, e in
            [
                "entry-\(idx)",
                "1",
                iso.string(from: e.at),
                iso.string(from: e.at),
                e.text
            ]
        }
        return CSVTable.make(kindColumns: cols, rows: rows)
    }

    static func parseCSVOverride(
        _ table: CSVTable,
        current: State,
        definition: Definition
    ) throws -> [ManualCorrection] {
        // Editable cell: `text`. rowID is "entry-<idx>" per renderCSV.
        var out: [ManualCorrection] = []
        for (_, row, entry) in CSVDiff.pairedRows(table: table, stateEntries: current.currentWeekEntries) {
            guard let newText = CSVDiff.cellAt(row: row, header: table.header, column: "text") else {
                continue
            }
            if newText != entry.text {
                let rowID = CSVDiff.cellAt(row: row, header: table.header, column: "__row_id")
                out.append(CSVDiff.correction(
                    rowID: rowID,
                    cell: "text",
                    oldValue: entry.text,
                    newValue: newText,
                    reason: "user edited text cell in data.csv"
                ))
            }
        }
        return out
    }

    // MARK: - Helpers

    private static func weekStart(for date: Date, weekStartDow: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = max(1, min(7, weekStartDow))
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    private static func previewOf(entries: [State.Entry]) -> String {
        guard !entries.isEmpty else { return "" }
        let joined = entries.map(\.text).joined(separator: " · ")
        if joined.count <= 240 { return joined }
        let cut = joined.index(joined.startIndex, offsetBy: 240)
        return String(joined[..<cut]) + "…"
    }
}
