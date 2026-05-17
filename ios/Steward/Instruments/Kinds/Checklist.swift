//
//  Checklist.swift
//  Steward
//
//  Spec §6: a daily / per-occurrence checklist (morning routine, room reset).
//  State tracks which items are checked today and a per-item streak counter
//  that decays on a missed day. All math here.
//

import Foundation

enum Checklist: InstrumentKind {

    // MARK: - Definition

    struct Definition: Codable, Sendable, Equatable {
        struct Item: Codable, Sendable, Equatable {
            let id: String          // stable per-item Id — the agent references this in events
            let label: String
            /// "daily" | "weekday" | "weekend" | nil (= daily implied)
            let recurrence: String?
        }
        var items: [Item]
    }

    // MARK: - State

    struct State: Codable, Sendable, Equatable {
        /// item Ids checked today (anchored to the calendar day of `lastResetAt`).
        var checkedToday: [String]
        /// Per-item streak: consecutive completed days, decremented on missed day.
        var streakByItem: [String: Int]
        /// Calendar-day anchor; we reset `checkedToday` to [] on day rollover.
        var lastResetAt: Date

        enum CodingKeys: String, CodingKey {
            case checkedToday = "checked_today"
            case streakByItem = "streak_by_item"
            case lastResetAt = "last_reset_at"
        }
    }

    // MARK: - EventPayload

    struct EventPayload: Codable, Sendable, Equatable {
        let itemID: String
        let checked: Bool

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case checked
        }
    }

    // MARK: - InstrumentKind

    static let id: String = "checklist"
    static let stateVersion: Int = 1

    static func initialState(definition: Definition, now: Date) -> State {
        var streaks: [String: Int] = [:]
        for item in definition.items { streaks[item.id] = 0 }
        let cal = Calendar(identifier: .gregorian)
        return State(
            checkedToday: [],
            streakByItem: streaks,
            lastResetAt: cal.startOfDay(for: now)
        )
    }

    static func apply(
        event: InstrumentEvent<EventPayload>,
        to state: State,
        definition: Definition,
        now: Date
    ) throws -> State {
        guard definition.items.contains(where: { $0.id == event.payload.itemID }) else {
            throw InstrumentKindError.invalidEventPayload(
                reason: "Checklist event references unknown itemID '\(event.payload.itemID)'"
            )
        }

        let cal = Calendar(identifier: .gregorian)
        let evDay = cal.startOfDay(for: event.createdAt)
        var working = state

        // Day rollover: if event is on a new calendar day, settle yesterday's
        // streaks (items checked → +1, items NOT checked → reset to 0) and
        // clear `checkedToday`.
        if evDay > state.lastResetAt {
            var newStreaks = state.streakByItem
            let yesterdayChecked = Set(state.checkedToday)
            for item in definition.items {
                let prev = newStreaks[item.id] ?? 0
                if yesterdayChecked.contains(item.id) {
                    newStreaks[item.id] = prev + 1
                } else {
                    // Respect recurrence: weekday-only items don't break streak
                    // on weekends, weekend-only items don't break on weekdays.
                    if isRequired(item: item, on: state.lastResetAt) {
                        newStreaks[item.id] = 0
                    }
                    // else: streak preserved on a non-required day.
                }
            }
            working = State(
                checkedToday: [],
                streakByItem: newStreaks,
                lastResetAt: evDay
            )
        }

        // Apply the check/uncheck.
        var checked = working.checkedToday
        if event.payload.checked {
            if !checked.contains(event.payload.itemID) {
                checked.append(event.payload.itemID)
            }
        } else {
            checked.removeAll { $0 == event.payload.itemID }
        }

        return State(
            checkedToday: checked,
            streakByItem: working.streakByItem,
            lastResetAt: working.lastResetAt
        )
    }

    static func applyManualCorrection(
        _ correction: ManualCorrection,
        to state: State,
        definition: Definition
    ) throws -> State {
        // CSV cell is "checked" (true/false) for a given item row. rowID is
        // the item Id. newValue is "true"/"false" (case-insensitive).
        guard let itemID = correction.rowID,
              definition.items.contains(where: { $0.id == itemID }) else {
            throw InstrumentKindError.unparseableCSV(
                reason: "Checklist correction rowID must be a known item Id, got \(correction.rowID ?? "nil")"
            )
        }
        guard let raw = correction.newValue?.lowercased() else {
            throw InstrumentKindError.unparseableCSV(reason: "Checklist correction missing newValue")
        }
        // Open-set String input → if/else chain (no exhaustive enum covers
        // CSV-friendly spellings). Keeps arch's "no switch-with-default".
        let truthy: Set<String> = ["true", "1", "yes", "y", "✓"]
        let falsy:  Set<String> = ["false", "0", "no", "n", ""]
        let shouldCheck: Bool
        if truthy.contains(raw) {
            shouldCheck = true
        } else if falsy.contains(raw) {
            shouldCheck = false
        } else {
            throw InstrumentKindError.unparseableCSV(
                reason: "Checklist correction newValue must be boolean-like, got '\(raw)'"
            )
        }
        var checked = state.checkedToday
        if shouldCheck {
            if !checked.contains(itemID) { checked.append(itemID) }
        } else {
            checked.removeAll { $0 == itemID }
        }
        return State(
            checkedToday: checked,
            streakByItem: state.streakByItem,
            lastResetAt: state.lastResetAt
        )
    }

    static func renderCSV(
        state: State,
        definition: Definition,
        recentEvents: [InstrumentEvent<EventPayload>]
    ) -> CSVTable {
        let cols = ["item_id", "label", "checked", "streak"]
        let iso = ISO8601DateFormatter()
        let rows: [[String]] = definition.items.map { item in
            [
                item.id,
                "1",
                iso.string(from: state.lastResetAt),
                item.id,
                item.label,
                state.checkedToday.contains(item.id) ? "true" : "false",
                String(state.streakByItem[item.id] ?? 0)
            ]
        }
        return CSVTable.make(kindColumns: cols, rows: rows)
    }

    static func parseCSVOverride(
        _ table: CSVTable,
        current: State,
        definition: Definition
    ) throws -> [ManualCorrection] {
        // Editable cell: `checked` (boolean-like). rowID = item.id.
        // Match by rowID directly (each Checklist item has a stable string ID).
        var out: [ManualCorrection] = []
        let truthy: Set<String> = ["true", "1", "yes", "y", "✓"]
        let falsy:  Set<String> = ["false", "0", "no", "n", ""]
        for row in table.rows {
            guard let rowID = CSVDiff.cellAt(row: row, header: table.header, column: "__row_id"),
                  definition.items.contains(where: { $0.id == rowID }) else {
                // Unknown rowID — skip rather than throw; Pod F may have a
                // stale row from a removed item.
                continue
            }
            guard let rawChecked = CSVDiff.cellAt(row: row, header: table.header, column: "checked")?.lowercased() else {
                continue
            }
            let newChecked: Bool
            if truthy.contains(rawChecked) {
                newChecked = true
            } else if falsy.contains(rawChecked) {
                newChecked = false
            } else {
                throw InstrumentKindError.unparseableCSV(
                    reason: "Checklist data.csv `checked` cell must be boolean-like, got '\(rawChecked)'"
                )
            }
            let oldChecked = current.checkedToday.contains(rowID)
            if newChecked != oldChecked {
                out.append(CSVDiff.correction(
                    rowID: rowID,
                    cell: "checked",
                    oldValue: oldChecked ? "true" : "false",
                    newValue: newChecked ? "true" : "false",
                    reason: "user toggled checked cell in data.csv"
                ))
            }
        }
        return out
    }

    // MARK: - Recurrence

    private static func isRequired(item: Definition.Item, on day: Date) -> Bool {
        let cal = Calendar(identifier: .gregorian)
        let weekday = cal.component(.weekday, from: day) // 1=Sun..7=Sat
        let isWeekend = (weekday == 1 || weekday == 7)
        // Open-set String input from definition JSON. Treat anything not
        // "weekday"/"weekend" as daily (per spec §6). if/else chain keeps
        // arch's "no switch-with-default" rule clean.
        let rec = (item.recurrence ?? "daily").lowercased()
        if rec == "weekday" { return !isWeekend }
        if rec == "weekend" { return isWeekend }
        return true
    }
}
