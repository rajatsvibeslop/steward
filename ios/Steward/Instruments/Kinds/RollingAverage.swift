//
//  RollingAverage.swift
//  Steward
//
//  Spec §6: rolling average over a window. Smoothing is either arithmetic
//  mean of in-window values or EMA (exponentially-weighted moving average).
//  Use cases: weight trend, sleep hours, mood.
//

import Foundation

enum RollingAverage: InstrumentKind {

    // MARK: - Definition

    enum Smoothing: String, Codable, Sendable, Equatable, CaseIterable {
        case mean, ema
    }

    struct Definition: Codable, Sendable, Equatable {
        var unit: String
        var windowDays: Int       // for `mean`: arithmetic average over in-window samples
        var smoothing: Smoothing  // for `ema`: alpha derived from `windowDays`

        enum CodingKeys: String, CodingKey {
            case unit
            case windowDays = "window_days"
            case smoothing
        }
    }

    // MARK: - State

    struct State: Codable, Sendable, Equatable {
        struct Sample: Codable, Sendable, Equatable {
            let at: Date
            let value: Double
        }
        var current: Double
        var windowValues: [Sample]   // pruned to the trailing window on every apply
        var lastEventAt: Date?

        enum CodingKeys: String, CodingKey {
            case current
            case windowValues = "window_values"
            case lastEventAt = "last_event_at"
        }
    }

    // MARK: - EventPayload

    struct EventPayload: Codable, Sendable, Equatable {
        let value: Double
    }

    // MARK: - InstrumentKind

    static let id: String = "rolling_average"
    static let stateVersion: Int = 1

    static func initialState(definition: Definition, now: Date) -> State {
        State(current: 0, windowValues: [], lastEventAt: nil)
    }

    static func apply(
        event: InstrumentEvent<EventPayload>,
        to state: State,
        definition: Definition,
        now: Date
    ) throws -> State {
        try validate(definition: definition)
        let sample = State.Sample(at: event.createdAt, value: event.payload.value)
        let combined = state.windowValues + [sample]
        let windowSeconds = Double(definition.windowDays) * 86_400
        let pruned = combined.filter { now.timeIntervalSince($0.at) <= windowSeconds }

        let current: Double
        switch definition.smoothing {
        case .mean:
            current = pruned.isEmpty ? 0 : pruned.map(\.value).reduce(0, +) / Double(pruned.count)
        case .ema:
            current = ema(samples: pruned, windowDays: definition.windowDays)
        }

        return State(current: current, windowValues: pruned, lastEventAt: event.createdAt)
    }

    static func applyManualCorrection(
        _ correction: ManualCorrection,
        to state: State,
        definition: Definition
    ) throws -> State {
        // The CSV's `current` column is the editable surface. Replacing it
        // would lose history, so we treat the correction as a brand-new sample
        // at correction time with the corrected value.
        guard let newRaw = correction.newValue,
              let newValue = Double(newRaw) else {
            throw InstrumentKindError.unparseableCSV(
                reason: "RollingAverage manual correction expected numeric newValue, got \(correction.newValue ?? "nil")"
            )
        }
        try validate(definition: definition)
        let sample = State.Sample(at: correction.appliedAt, value: newValue)
        let combined = state.windowValues + [sample]
        let windowSeconds = Double(definition.windowDays) * 86_400
        let pruned = combined.filter { correction.appliedAt.timeIntervalSince($0.at) <= windowSeconds }
        let current: Double
        switch definition.smoothing {
        case .mean:
            current = pruned.isEmpty ? 0 : pruned.map(\.value).reduce(0, +) / Double(pruned.count)
        case .ema:
            current = ema(samples: pruned, windowDays: definition.windowDays)
        }
        return State(current: current, windowValues: pruned, lastEventAt: correction.appliedAt)
    }

    static func renderCSV(
        state: State,
        definition: Definition,
        recentEvents: [InstrumentEvent<EventPayload>]
    ) -> CSVTable {
        let cols = ["sample_at", "value", "current"]
        let iso = ISO8601DateFormatter()
        let rows: [[String]] = state.windowValues.map { s in
            [
                "sample-\(Int(s.at.timeIntervalSince1970 * 1000))",
                "1",
                iso.string(from: s.at),
                iso.string(from: s.at),
                String(s.value),
                String(state.current)
            ]
        }
        return CSVTable.make(kindColumns: cols, rows: rows)
    }

    static func parseCSVOverride(
        _ table: CSVTable,
        current: State,
        definition: Definition
    ) throws -> [ManualCorrection] {
        // Editable cell: `value` per window sample. `current` is render-only.
        var out: [ManualCorrection] = []
        for (_, row, sample) in CSVDiff.pairedRows(table: table, stateEntries: current.windowValues) {
            guard let valueStr = CSVDiff.cellAt(row: row, header: table.header, column: "value"),
                  let newValue = Double(valueStr) else {
                throw InstrumentKindError.unparseableCSV(
                    reason: "RollingAverage data.csv row missing or non-numeric `value` cell"
                )
            }
            if newValue != sample.value {
                let rowID = CSVDiff.cellAt(row: row, header: table.header, column: "__row_id")
                out.append(CSVDiff.correction(
                    rowID: rowID,
                    cell: "value",
                    oldValue: String(sample.value),
                    newValue: String(newValue),
                    reason: "user edited value cell in data.csv"
                ))
            }
        }
        return out
    }

    // MARK: - Math

    private static func validate(definition: Definition) throws {
        if definition.windowDays <= 0 {
            throw InstrumentKindError.invalidDefinition(
                reason: "RollingAverage.windowDays must be > 0, got \(definition.windowDays)"
            )
        }
    }

    /// Order-sensitive EMA over the in-window samples (oldest → newest).
    /// `alpha = 2 / (N + 1)` per the standard EMA convention.
    private static func ema(samples: [State.Sample], windowDays: Int) -> Double {
        guard !samples.isEmpty else { return 0 }
        let ordered = samples.sorted { $0.at < $1.at }
        let alpha = 2.0 / (Double(windowDays) + 1.0)
        var current = ordered[0].value
        for i in 1..<ordered.count {
            current = alpha * ordered[i].value + (1.0 - alpha) * current
        }
        return current
    }
}
