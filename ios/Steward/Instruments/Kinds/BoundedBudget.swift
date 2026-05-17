//
//  BoundedBudget.swift
//  Steward
//
//  Spec §6: bounded budget per period (daily / weekly / monthly). Tracks
//  `period_total`, `remaining`, `period_start_at`, recent entries. Rollover
//  optional. Math is deterministic Swift — `now` decides period boundaries.
//

import Foundation

enum BoundedBudget: InstrumentKind {

    // MARK: - Definition

    enum Period: String, Codable, Sendable, Equatable, CaseIterable {
        case daily, weekly, monthly
    }

    struct Definition: Codable, Sendable, Equatable {
        var unit: String          // "USD", "minutes", "items"
        var period: Period
        var limit: Double         // budget amount per period
        var rollover: Bool        // unused remaining carries to next period
    }

    // MARK: - State

    struct State: Codable, Sendable, Equatable {
        struct Entry: Codable, Sendable, Equatable {
            let at: Date
            let value: Double
            let notes: String?
        }
        var periodStartAt: Date
        var periodTotal: Double
        var remaining: Double
        var recentEntries: [Entry]     // tail of in-period entries (cap 50)
        var rolloverBalance: Double    // carried from previous period if rollover=true

        enum CodingKeys: String, CodingKey {
            case periodStartAt = "period_start_at"
            case periodTotal = "period_total"
            case remaining
            case recentEntries = "recent_entries"
            case rolloverBalance = "rollover_balance"
        }
    }

    // MARK: - EventPayload

    struct EventPayload: Codable, Sendable, Equatable {
        let value: Double
        let notes: String?
    }

    // MARK: - InstrumentKind

    static let id: String = "bounded_budget"
    static let stateVersion: Int = 1

    static func initialState(definition: Definition, now: Date) -> State {
        State(
            periodStartAt: periodStart(for: definition.period, anchored: now),
            periodTotal: 0,
            remaining: definition.limit,
            recentEntries: [],
            rolloverBalance: 0
        )
    }

    static func apply(
        event: InstrumentEvent<EventPayload>,
        to state: State,
        definition: Definition,
        now: Date
    ) throws -> State {
        // Roll the period forward if `now` is past the next boundary.
        var carried = state
        let currentPeriodStart = periodStart(for: definition.period, anchored: now)
        if currentPeriodStart > carried.periodStartAt {
            let previousRemaining = carried.remaining
            carried = State(
                periodStartAt: currentPeriodStart,
                periodTotal: 0,
                remaining: definition.limit + (definition.rollover ? max(previousRemaining, 0) : 0),
                recentEntries: [],
                rolloverBalance: definition.rollover ? max(previousRemaining, 0) : 0
            )
        }

        let entry = State.Entry(at: event.createdAt, value: event.payload.value, notes: event.payload.notes)
        let recent = (carried.recentEntries + [entry]).suffix(50)
        let newTotal = carried.periodTotal + event.payload.value
        return State(
            periodStartAt: carried.periodStartAt,
            periodTotal: newTotal,
            remaining: (definition.limit + carried.rolloverBalance) - newTotal,
            recentEntries: Array(recent),
            rolloverBalance: carried.rolloverBalance
        )
    }

    static func applyManualCorrection(
        _ correction: ManualCorrection,
        to state: State,
        definition: Definition
    ) throws -> State {
        // The CSV's `period_total` is editable; everything else is recomputed.
        guard let newRaw = correction.newValue,
              let newTotal = Double(newRaw) else {
            throw InstrumentKindError.unparseableCSV(
                reason: "BoundedBudget manual correction expected numeric newValue, got \(correction.newValue ?? "nil")"
            )
        }
        return State(
            periodStartAt: state.periodStartAt,
            periodTotal: newTotal,
            remaining: (definition.limit + state.rolloverBalance) - newTotal,
            recentEntries: state.recentEntries,
            rolloverBalance: state.rolloverBalance
        )
    }

    static func renderCSV(
        state: State,
        definition: Definition,
        recentEvents: [InstrumentEvent<EventPayload>]
    ) -> CSVTable {
        let cols = ["entry_at", "value", "notes", "period_total", "remaining", "rollover_balance"]
        let iso = ISO8601DateFormatter()
        let rows: [[String]] = state.recentEntries.map { e in
            [
                "entry-\(Int(e.at.timeIntervalSince1970 * 1000))",
                "1",
                iso.string(from: e.at),
                iso.string(from: e.at),
                String(e.value),
                e.notes ?? "",
                String(state.periodTotal),
                String(state.remaining),
                String(state.rolloverBalance)
            ]
        }
        return CSVTable.make(kindColumns: cols, rows: rows)
    }

    static func parseCSVOverride(
        _ table: CSVTable,
        current: State,
        definition: Definition
    ) throws -> [ManualCorrection] {
        // Editable cells: `value` (spend amount) + `notes` per recent entry.
        // period_total / remaining / rollover_balance are render-only and
        // recomputed from value edits.
        var out: [ManualCorrection] = []
        for (_, row, entry) in CSVDiff.pairedRows(table: table, stateEntries: current.recentEntries) {
            let rowID = CSVDiff.cellAt(row: row, header: table.header, column: "__row_id")
            // value
            if let valueStr = CSVDiff.cellAt(row: row, header: table.header, column: "value"),
               let newValue = Double(valueStr),
               newValue != entry.value {
                out.append(CSVDiff.correction(
                    rowID: rowID,
                    cell: "value",
                    oldValue: String(entry.value),
                    newValue: String(newValue),
                    reason: "user edited value cell in data.csv"
                ))
            }
            // notes
            if let newNotes = CSVDiff.cellAt(row: row, header: table.header, column: "notes") {
                let oldNotes = entry.notes ?? ""
                if newNotes != oldNotes {
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
        return out
    }

    // MARK: - Period math

    /// Start of the current period containing `anchored`. Pure function of
    /// `period` + `anchored` + the gregorian calendar. Week starts Monday
    /// (RFC 5545 / ISO 8601 weekly convention).
    static func periodStart(for period: Period, anchored: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2  // Monday — matches ISO 8601 week semantics.
        switch period {
        case .daily:
            return cal.startOfDay(for: anchored)
        case .weekly:
            let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchored)
            return cal.date(from: components) ?? cal.startOfDay(for: anchored)
        case .monthly:
            let components = cal.dateComponents([.year, .month], from: anchored)
            return cal.date(from: components) ?? cal.startOfDay(for: anchored)
        }
    }
}
