//
//  BoundedWindow.swift
//  Steward
//
//  Spec §6: bounded window (sleep window adherence). Each event reports a
//  start time and an end time (e.g., sleep onset and wake). Compliance is
//  the fraction of recent nights whose window fell inside the target window.
//

import Foundation

enum BoundedWindow: InstrumentKind {

    // MARK: - Definition

    enum ComplianceMetric: String, Codable, Sendable, Equatable, CaseIterable {
        case nightsInWindow  // % of last N nights whose [actualStart, actualEnd] ⊆ [targetStart, targetEnd]
        case durationMet     // % of nights whose duration ≥ (targetEnd - targetStart)
    }

    struct Definition: Codable, Sendable, Equatable {
        /// "kind" qualifier from the spec — kept for forward-compat (only
        /// `time_window` exists today, but the column reserves the slot).
        var kind: String         // "time_window"
        var startTarget: String  // "HH:mm" (e.g. "22:30")
        var endTarget: String    // "HH:mm" (e.g. "06:30")
        var complianceMetric: ComplianceMetric
        /// Number of trailing nights used for the rolling compliance %.
        var rollingWindowNights: Int

        enum CodingKeys: String, CodingKey {
            case kind
            case startTarget = "start_target"
            case endTarget = "end_target"
            case complianceMetric = "compliance_metric"
            case rollingWindowNights = "rolling_window_nights"
        }
    }

    // MARK: - State

    struct State: Codable, Sendable, Equatable {
        struct NightSample: Codable, Sendable, Equatable {
            /// The calendar day that owns this night (the morning's date).
            let date: Date
            let actualStart: Date
            let actualEnd: Date
            let inWindow: Bool
        }
        var nightsInWindow: [NightSample]      // trailing rollingWindowNights samples
        var currentCompliancePct: Double        // 0.0 ... 1.0

        enum CodingKeys: String, CodingKey {
            case nightsInWindow = "nights_in_window"
            case currentCompliancePct = "current_compliance_pct"
        }
    }

    // MARK: - EventPayload

    struct EventPayload: Codable, Sendable, Equatable {
        let actualStart: Date
        let actualEnd: Date

        enum CodingKeys: String, CodingKey {
            case actualStart = "actual_start"
            case actualEnd = "actual_end"
        }
    }

    // MARK: - InstrumentKind

    static let id: String = "bounded_window"
    static let stateVersion: Int = 1

    static func initialState(definition: Definition, now: Date) -> State {
        State(nightsInWindow: [], currentCompliancePct: 0)
    }

    static func apply(
        event: InstrumentEvent<EventPayload>,
        to state: State,
        definition: Definition,
        now: Date
    ) throws -> State {
        try validate(definition: definition)
        let cal = Calendar(identifier: .gregorian)
        let nightDate = cal.startOfDay(for: event.payload.actualEnd)

        let sample = State.NightSample(
            date: nightDate,
            actualStart: event.payload.actualStart,
            actualEnd: event.payload.actualEnd,
            inWindow: try evaluate(sample: event.payload, definition: definition)
        )

        let combined = (state.nightsInWindow + [sample]).suffix(definition.rollingWindowNights)
        let arr = Array(combined)
        let pct = arr.isEmpty
            ? 0
            : Double(arr.filter(\.inWindow).count) / Double(arr.count)

        return State(nightsInWindow: arr, currentCompliancePct: pct)
    }

    static func applyManualCorrection(
        _ correction: ManualCorrection,
        to state: State,
        definition: Definition
    ) throws -> State {
        // BoundedWindow corrections target `currentCompliancePct` directly.
        // The user told the system "I was in window last night" without
        // entering precise times.
        guard let raw = correction.newValue,
              let pct = Double(raw) else {
            throw InstrumentKindError.unparseableCSV(
                reason: "BoundedWindow correction expected numeric (0..1) newValue, got \(correction.newValue ?? "nil")"
            )
        }
        return State(
            nightsInWindow: state.nightsInWindow,
            currentCompliancePct: max(0, min(1, pct))
        )
    }

    static func renderCSV(
        state: State,
        definition: Definition,
        recentEvents: [InstrumentEvent<EventPayload>]
    ) -> CSVTable {
        let cols = ["night_date", "actual_start", "actual_end", "in_window", "compliance_pct"]
        let iso = ISO8601DateFormatter()
        let rows: [[String]] = state.nightsInWindow.map { n in
            [
                "night-\(Int(n.date.timeIntervalSince1970))",
                "1",
                iso.string(from: n.actualEnd),
                iso.string(from: n.date),
                iso.string(from: n.actualStart),
                iso.string(from: n.actualEnd),
                n.inWindow ? "true" : "false",
                String(state.currentCompliancePct)
            ]
        }
        return CSVTable.make(kindColumns: cols, rows: rows)
    }

    static func parseCSVOverride(
        _ table: CSVTable,
        current: State,
        definition: Definition
    ) throws -> [ManualCorrection] {
        // Editable cells: `actual_start` and `actual_end` per night row.
        // in_window + compliance_pct are render-only (recomputed).
        let iso = ISO8601DateFormatter()
        var out: [ManualCorrection] = []
        for (_, row, night) in CSVDiff.pairedRows(table: table, stateEntries: current.nightsInWindow) {
            let rowID = CSVDiff.cellAt(row: row, header: table.header, column: "__row_id")
            // actual_start
            if let newStartStr = CSVDiff.cellAt(row: row, header: table.header, column: "actual_start"),
               let newStart = iso.date(from: newStartStr),
               newStart != night.actualStart {
                out.append(CSVDiff.correction(
                    rowID: rowID,
                    cell: "actual_start",
                    oldValue: iso.string(from: night.actualStart),
                    newValue: newStartStr,
                    reason: "user edited actual_start cell in data.csv"
                ))
            }
            // actual_end
            if let newEndStr = CSVDiff.cellAt(row: row, header: table.header, column: "actual_end"),
               let newEnd = iso.date(from: newEndStr),
               newEnd != night.actualEnd {
                out.append(CSVDiff.correction(
                    rowID: rowID,
                    cell: "actual_end",
                    oldValue: iso.string(from: night.actualEnd),
                    newValue: newEndStr,
                    reason: "user edited actual_end cell in data.csv"
                ))
            }
        }
        return out
    }

    // MARK: - Math

    private static func validate(definition: Definition) throws {
        if definition.rollingWindowNights <= 0 {
            throw InstrumentKindError.invalidDefinition(
                reason: "BoundedWindow.rollingWindowNights must be > 0, got \(definition.rollingWindowNights)"
            )
        }
        if parseHHMM(definition.startTarget) == nil {
            throw InstrumentKindError.invalidDefinition(reason: "BoundedWindow.startTarget must be HH:mm, got '\(definition.startTarget)'")
        }
        if parseHHMM(definition.endTarget) == nil {
            throw InstrumentKindError.invalidDefinition(reason: "BoundedWindow.endTarget must be HH:mm, got '\(definition.endTarget)'")
        }
    }

    private static func evaluate(sample: EventPayload, definition: Definition) throws -> Bool {
        switch definition.complianceMetric {
        case .nightsInWindow:
            guard let target = absoluteTargetWindow(
                startTarget: definition.startTarget,
                endTarget: definition.endTarget,
                anchored: sample.actualEnd
            ) else {
                throw InstrumentKindError.invalidDefinition(
                    reason: "BoundedWindow target window unresolvable for end \(definition.endTarget)"
                )
            }
            return sample.actualStart >= target.start && sample.actualEnd <= target.end
        case .durationMet:
            guard let target = absoluteTargetWindow(
                startTarget: definition.startTarget,
                endTarget: definition.endTarget,
                anchored: sample.actualEnd
            ) else {
                return false
            }
            let actualDur = sample.actualEnd.timeIntervalSince(sample.actualStart)
            let targetDur = target.end.timeIntervalSince(target.start)
            return actualDur >= targetDur
        }
    }

    /// Resolve "HH:mm → HH:mm" against a concrete day. If end < start (e.g.
    /// 22:30 → 06:30), end rolls into the next calendar day. Anchored on
    /// `anchored`'s calendar date for the END portion; the START is pinned
    /// to the prior day if it crosses midnight.
    private static func absoluteTargetWindow(
        startTarget: String,
        endTarget: String,
        anchored: Date
    ) -> DateInterval? {
        guard let startHM = parseHHMM(startTarget),
              let endHM = parseHHMM(endTarget) else { return nil }
        // v1 simplification: interpret HH:mm targets in UTC so the math is
        // deterministic across test machines and devices. The user's local-
        // time interpretation lives in Track D's NotificationTemplate, which
        // converts to local on render. v1.1: add TimeZone to Definition.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let dayStart = cal.startOfDay(for: anchored)

        let startSameDay = cal.date(bySettingHour: startHM.h, minute: startHM.m, second: 0, of: dayStart)
        let endSameDay = cal.date(bySettingHour: endHM.h, minute: endHM.m, second: 0, of: dayStart)
        guard let startSame = startSameDay, let endSame = endSameDay else { return nil }

        if endSame <= startSame {
            // crosses midnight: start belongs to the previous day
            let startPrev = cal.date(byAdding: .day, value: -1, to: startSame) ?? startSame
            return DateInterval(start: startPrev, end: endSame)
        } else {
            return DateInterval(start: startSame, end: endSame)
        }
    }

    private static func parseHHMM(_ s: String) -> (h: Int, m: Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }
}
