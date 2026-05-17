//
//  CountdownCommitment.swift
//  Steward
//
//  Spec §6: "do X N times this window" — countdown_commitment. Tracks count
//  toward target within a rolling/anchored window (day | week | month).
//  Example: "three workplace push-backs this week".
//

import Foundation

enum CountdownCommitment: InstrumentKind {

    // MARK: - Definition

    enum Window: String, Codable, Sendable, Equatable, CaseIterable {
        case day, week, month
    }

    struct Definition: Codable, Sendable, Equatable {
        var targetCount: Int
        var window: Window
        /// Event sub-kind that counts as a completion (e.g. "push_back").
        /// The agent emits `event_kind = successEventKind` on
        /// `instrument.apply_event` to bump the counter.
        var successEventKind: String

        enum CodingKeys: String, CodingKey {
            case targetCount = "target_count"
            case window
            case successEventKind = "success_event_kind"
        }
    }

    // MARK: - State

    struct State: Codable, Sendable, Equatable {
        struct CompletedEvent: Codable, Sendable, Equatable {
            let eventID: EventID
            let at: Date
            let notes: String?
        }
        var count: Int
        var target: Int
        var windowStart: Date
        var windowEnd: Date
        var completedEvents: [CompletedEvent]

        enum CodingKeys: String, CodingKey {
            case count
            case target
            case windowStart = "window_start"
            case windowEnd = "window_end"
            case completedEvents = "completed_events"
        }
    }

    // MARK: - EventPayload

    struct EventPayload: Codable, Sendable, Equatable {
        let notes: String?
    }

    // MARK: - InstrumentKind

    static let id: String = "countdown_commitment"
    static let stateVersion: Int = 1

    static func initialState(definition: Definition, now: Date) -> State {
        let interval = window(for: definition.window, anchored: now)
        return State(
            count: 0,
            target: definition.targetCount,
            windowStart: interval.start,
            windowEnd: interval.end,
            completedEvents: []
        )
    }

    static func apply(
        event: InstrumentEvent<EventPayload>,
        to state: State,
        definition: Definition,
        now: Date
    ) throws -> State {
        // Only events whose envelope kind matches the configured
        // successEventKind count. Anything else is recorded by the caller
        // as a generic event but doesn't touch this state machine.
        if event.kind != definition.successEventKind {
            throw InstrumentKindError.invalidEventPayload(
                reason: "CountdownCommitment expected event.kind=\"\(definition.successEventKind)\", got \"\(event.kind)\""
            )
        }

        // Roll window if we're past the end.
        let interval: DateInterval
        var working = state
        if event.createdAt >= state.windowEnd {
            interval = window(for: definition.window, anchored: event.createdAt)
            working = State(
                count: 0,
                target: definition.targetCount,
                windowStart: interval.start,
                windowEnd: interval.end,
                completedEvents: []
            )
        } else {
            interval = DateInterval(start: state.windowStart, end: state.windowEnd)
        }

        let entry = State.CompletedEvent(eventID: event.eventID, at: event.createdAt, notes: event.payload.notes)
        return State(
            count: working.count + 1,
            target: definition.targetCount,
            windowStart: interval.start,
            windowEnd: interval.end,
            completedEvents: working.completedEvents + [entry]
        )
    }

    static func applyManualCorrection(
        _ correction: ManualCorrection,
        to state: State,
        definition: Definition
    ) throws -> State {
        // CSV `count` column is the editable surface; overwrite directly.
        // Completion list is left alone — diverging from `count` is acceptable
        // because the user explicitly forced a number.
        guard let newRaw = correction.newValue,
              let newCount = Int(newRaw) else {
            throw InstrumentKindError.unparseableCSV(
                reason: "CountdownCommitment manual correction expected integer newValue, got \(correction.newValue ?? "nil")"
            )
        }
        return State(
            count: newCount,
            target: state.target,
            windowStart: state.windowStart,
            windowEnd: state.windowEnd,
            completedEvents: state.completedEvents
        )
    }

    static func renderCSV(
        state: State,
        definition: Definition,
        recentEvents: [InstrumentEvent<EventPayload>]
    ) -> CSVTable {
        let cols = ["completed_at", "notes", "count", "target"]
        let iso = ISO8601DateFormatter()
        let rows: [[String]] = state.completedEvents.map { c in
            [
                c.eventID.rawValue,
                "1",
                iso.string(from: c.at),
                iso.string(from: c.at),
                c.notes ?? "",
                String(state.count),
                String(state.target)
            ]
        }
        return CSVTable.make(kindColumns: cols, rows: rows)
    }

    static func parseCSVOverride(
        _ table: CSVTable,
        current: State,
        definition: Definition
    ) throws -> [ManualCorrection] {
        // Editable cells: `notes` per completed event row, AND `count` (the
        // denormalized total). `count` is the same in every row — we only
        // emit one correction (from the first row) if it differs.
        var out: [ManualCorrection] = []

        // notes per row
        for (_, row, completed) in CSVDiff.pairedRows(table: table, stateEntries: current.completedEvents) {
            if let newNotes = CSVDiff.cellAt(row: row, header: table.header, column: "notes") {
                let oldNotes = completed.notes ?? ""
                if newNotes != oldNotes {
                    let rowID = CSVDiff.cellAt(row: row, header: table.header, column: "__row_id")
                    out.append(CSVDiff.correction(
                        rowID: rowID,
                        cell: "notes",
                        oldValue: oldNotes,
                        newValue: newNotes,
                        reason: "user edited notes cell in data.csv"
                    ))
                }
            }
        }

        // count (denormalized; check first row only)
        if let firstRow = table.rows.first,
           let newCountStr = CSVDiff.cellAt(row: firstRow, header: table.header, column: "count"),
           let newCount = Int(newCountStr),
           newCount != current.count {
            out.append(CSVDiff.correction(
                rowID: CSVDiff.cellAt(row: firstRow, header: table.header, column: "__row_id"),
                cell: "count",
                oldValue: String(current.count),
                newValue: String(newCount),
                reason: "user edited count cell in data.csv"
            ))
        }
        return out
    }

    // MARK: - Window math

    static func window(for w: Window, anchored: Date) -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        switch w {
        case .day:
            let start = cal.startOfDay(for: anchored)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return DateInterval(start: start, end: end)
        case .week:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchored)
            let start = cal.date(from: comps) ?? cal.startOfDay(for: anchored)
            let end = cal.date(byAdding: .weekOfYear, value: 1, to: start) ?? start.addingTimeInterval(7 * 86_400)
            return DateInterval(start: start, end: end)
        case .month:
            let comps = cal.dateComponents([.year, .month], from: anchored)
            let start = cal.date(from: comps) ?? cal.startOfDay(for: anchored)
            let end = cal.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(30 * 86_400)
            return DateInterval(start: start, end: end)
        }
    }
}
