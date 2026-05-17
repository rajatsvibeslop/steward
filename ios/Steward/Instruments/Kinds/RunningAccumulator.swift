//
//  RunningAccumulator.swift
//  Steward
//
//  Spec §6: tracks a quantity that accumulates over time (productive hours,
//  movement minutes, water intake). State carries the running totals; the
//  agent reads them via `instrument.read` and never invents a number
//  (hard reject #1).
//
//  All arithmetic — totals, rolling averages, day-bucket resets — is in this
//  file's `apply()`. Deterministic given (event, state, definition, now).
//

import Foundation

enum RunningAccumulator: InstrumentKind {

    // MARK: - Definition

    /// Created by `instrument.create`. Persistent for the instrument's life
    /// (mutated only via `update_definition`).
    struct Definition: Codable, Sendable, Equatable {
        var unit: String                  // "minutes", "ounces", "hours"
        var dailyTarget: Double?
        var weeklyTarget: Double?
        var capturePrompt: String         // user-facing prompt the agent may use

        enum CodingKeys: String, CodingKey {
            case unit
            case dailyTarget = "daily_target"
            case weeklyTarget = "weekly_target"
            case capturePrompt = "capture_prompt"
        }
    }

    // MARK: - State

    /// Persisted state. `windowEvents` is the rolling 30-day tail (one entry per
    /// event); we recompute today/7-day/30-day totals from it on every apply
    /// rather than caching denormalized numbers that can drift.
    struct State: Codable, Sendable, Equatable {
        /// One entry per applied event, ISO-8601 timestamp + value. Pruned
        /// to the trailing 30 days on every apply so the blob doesn't grow
        /// unbounded.
        struct Entry: Codable, Sendable, Equatable {
            let at: Date
            let value: Double
        }
        var windowEvents: [Entry]
        var todayTotal: Double
        var sevenDayAvg: Double
        var thirtyDayAvg: Double
        var lastEventAt: Date?

        enum CodingKeys: String, CodingKey {
            case windowEvents = "window_events"
            case todayTotal = "today_total"
            case sevenDayAvg = "seven_day_avg"
            case thirtyDayAvg = "thirty_day_avg"
            case lastEventAt = "last_event_at"
        }
    }

    // MARK: - EventPayload

    struct EventPayload: Codable, Sendable, Equatable {
        /// Quantity to add. Negative values are allowed (the agent may log a
        /// correction); a separate `subtract` event kind isn't needed.
        let value: Double
        /// Echoed for audit. The instrument's definition is the source of truth.
        let unit: String?
    }

    // MARK: - InstrumentKind

    static let id: String = "running_accumulator"
    static let stateVersion: Int = 1

    static func initialState(definition: Definition, now: Date) -> State {
        State(
            windowEvents: [],
            todayTotal: 0,
            sevenDayAvg: 0,
            thirtyDayAvg: 0,
            lastEventAt: nil
        )
    }

    static func apply(
        event: InstrumentEvent<EventPayload>,
        to state: State,
        definition: Definition,
        now: Date
    ) throws -> State {
        let entry = State.Entry(at: event.createdAt, value: event.payload.value)
        let pruned = (state.windowEvents + [entry])
            .filter { now.timeIntervalSince($0.at) <= 30 * 86_400 }
        return State(
            windowEvents: pruned,
            todayTotal: total(of: pruned, withinSeconds: secondsSinceStartOfDay(now)),
            sevenDayAvg: rollingAverage(of: pruned, windowDays: 7, now: now),
            thirtyDayAvg: rollingAverage(of: pruned, windowDays: 30, now: now),
            lastEventAt: event.createdAt
        )
    }

    static func applyManualCorrection(
        _ correction: ManualCorrection,
        to state: State,
        definition: Definition
    ) throws -> State {
        // Manual corrections target `todayTotal` directly (the user typed a
        // number into the CSV). Reconstruct by appending a synthetic delta
        // entry at correction time so the rolling averages stay coherent.
        guard let newRaw = correction.newValue,
              let newValue = Double(newRaw) else {
            throw InstrumentKindError.unparseableCSV(
                reason: "RunningAccumulator manual correction expected numeric newValue, got \(correction.newValue ?? "nil")"
            )
        }
        let delta = newValue - state.todayTotal
        let synthetic = State.Entry(at: correction.appliedAt, value: delta)
        let pruned = (state.windowEvents + [synthetic])
            .filter { correction.appliedAt.timeIntervalSince($0.at) <= 30 * 86_400 }
        return State(
            windowEvents: pruned,
            todayTotal: newValue,
            sevenDayAvg: rollingAverage(of: pruned, windowDays: 7, now: correction.appliedAt),
            thirtyDayAvg: rollingAverage(of: pruned, windowDays: 30, now: correction.appliedAt),
            lastEventAt: correction.appliedAt
        )
    }

    static func renderCSV(
        state: State,
        definition: Definition,
        recentEvents: [InstrumentEvent<EventPayload>]
    ) -> CSVTable {
        let cols = ["date", "value", "unit", "today_total", "seven_day_avg", "thirty_day_avg"]
        let iso = ISO8601DateFormatter()
        let rows: [[String]] = recentEvents.map { ev in
            [
                ev.eventID.rawValue,
                "1",
                iso.string(from: ev.createdAt),
                iso.string(from: ev.createdAt),
                String(ev.payload.value),
                ev.payload.unit ?? definition.unit,
                String(state.todayTotal),
                String(state.sevenDayAvg),
                String(state.thirtyDayAvg)
            ]
        }
        return CSVTable.make(kindColumns: cols, rows: rows)
    }

    static func parseCSVOverride(
        _ table: CSVTable,
        current: State,
        definition: Definition
    ) throws -> [ManualCorrection] {
        // Editable cell: `value`. Totals (today_total, seven_day_avg,
        // thirty_day_avg) are render-only — edits there are silently
        // ignored. Match table rows to state.windowEvents by chronological
        // index (Pod F's CSV preserves render order).
        var out: [ManualCorrection] = []
        for (_, row, entry) in CSVDiff.pairedRows(table: table, stateEntries: current.windowEvents) {
            guard let valueStr = CSVDiff.cellAt(row: row, header: table.header, column: "value"),
                  let newValue = Double(valueStr) else {
                throw InstrumentKindError.unparseableCSV(
                    reason: "RunningAccumulator data.csv row missing or non-numeric `value` cell"
                )
            }
            let oldValue = entry.value
            if newValue != oldValue {
                let rowID = CSVDiff.cellAt(row: row, header: table.header, column: "__row_id")
                out.append(CSVDiff.correction(
                    rowID: rowID,
                    cell: "value",
                    oldValue: String(oldValue),
                    newValue: String(newValue),
                    reason: "user edited value cell in data.csv"
                ))
            }
        }
        return out
    }

    // MARK: - Math (private; pure)

    private static func secondsSinceStartOfDay(_ now: Date) -> TimeInterval {
        let cal = Calendar(identifier: .gregorian)
        let start = cal.startOfDay(for: now)
        return now.timeIntervalSince(start)
    }

    private static func total(of entries: [State.Entry], withinSeconds seconds: TimeInterval) -> Double {
        // Sum entries whose `at` is within `seconds` of the latest entry.
        // For `today`, we sum from start-of-day, which the caller approximates
        // via `secondsSinceStartOfDay(now)`. We anchor to `now` (= entries.last?.at
        // ?? now) to keep the function pure-of-clock.
        guard let last = entries.last?.at else { return 0 }
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: last)
        return entries
            .filter { $0.at >= dayStart }
            .map(\.value)
            .reduce(0, +)
    }

    private static func rollingAverage(of entries: [State.Entry], windowDays: Int, now: Date) -> Double {
        let windowSeconds = Double(windowDays) * 86_400
        let inWindow = entries.filter { now.timeIntervalSince($0.at) <= windowSeconds }
        guard !inWindow.isEmpty else { return 0 }
        // Daily average over the window, even on days with zero events. We
        // divide the sum by the window-day count (not the event count) so a
        // "10 minutes once a week" pattern shows ~1.4/day, not 10/day.
        let total = inWindow.map(\.value).reduce(0, +)
        return total / Double(windowDays)
    }
}
