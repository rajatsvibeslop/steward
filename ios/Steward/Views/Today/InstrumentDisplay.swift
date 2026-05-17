//
//  InstrumentDisplay.swift
//  Steward — Track E
//
//  Per-kind value/delta projection for the Today tab's instrument cards
//  (Designer §2.3). Read-only.
//
//  ARCH NOTE (vetted): display-only switch on kindID is permitted; behavioral
//  dispatch must go through `InstrumentRegistry` per addendum §1.2 + §4 #9.
//  The switch below MUST be exhaustive (all 7 kinds enumerated). When a new
//  kind lands, the compile signal in this file is the prompt to add display
//  logic — there is no `default:` arm.
//
//  The function consumes a kind id + state JSON + definition JSON and returns
//  an `InstrumentDisplay` view-model (primary value + delta line + optional
//  stale-since line). Decoding failures yield a `.unreadable` summary so the
//  card still renders rather than crashing.
//

import Foundation

struct InstrumentDisplay: Equatable {
    let primary: String
    let unit: String?
    let delta: DeltaLine
    let staleLabel: String?

    enum DeltaLine: Equatable {
        case improvement(text: String)
        case worse(text: String)
        case neutral(text: String)
        case none

        /// SF Symbol name to render leading of the text.
        var symbol: String {
            switch self {
            case .improvement: return "arrow.up.right"
            case .worse:       return "arrow.down.right"
            case .neutral:     return "arrow.right"
            case .none:        return ""
            }
        }

        var text: String {
            switch self {
            case .improvement(let t), .worse(let t), .neutral(let t): return t
            case .none: return ""
            }
        }
    }

    static let unreadable = InstrumentDisplay(
        primary: "—",
        unit: nil,
        delta: .none,
        staleLabel: "Couldn't read this one. Tap to retry."
    )
}

enum InstrumentDisplayProjector {
    static func project(
        kindID: String,
        stateJSON: String,
        definitionJSON: String,
        lastUpdatedAt: Date,
        now: Date = Date()
    ) -> InstrumentDisplay {
        let staleLabel = staleLabel(lastUpdatedAt: lastUpdatedAt, now: now)
        let projected = projectKind(
            kindID: kindID,
            stateJSON: stateJSON,
            definitionJSON: definitionJSON
        ) ?? InstrumentDisplay.unreadable
        return InstrumentDisplay(
            primary: projected.primary,
            unit: projected.unit,
            delta: projected.delta,
            staleLabel: projected.staleLabel ?? staleLabel
        )
    }

    /// Display-only enum mirror of the 7 kinds registered by
    /// `InstrumentRegistry.bootstrapAll()`. Adding a new InstrumentKind means
    /// adding a case here AND adding its display projection — both compile
    /// errors until handled, which is exactly the signal we want.
    private enum DisplayKind: String, CaseIterable {
        case runningAccumulator   = "running_accumulator"
        case boundedBudget        = "bounded_budget"
        case rollingAverage       = "rolling_average"
        case countdownCommitment  = "countdown_commitment"
        case weeklyEvidenceLog    = "weekly_evidence_log"
        case checklist            = "checklist"
        case boundedWindow        = "bounded_window"
    }

    /// Returns nil on any decode failure; caller substitutes `.unreadable`.
    /// Unknown kind id (not in our DisplayKind enum) also yields nil — UI
    /// renders `.unreadable` rather than crashing. The exhaustive switch on
    /// `DisplayKind` is the §4-#9-compliant shape: kindID parsing is
    /// localized, and behavioral dispatch still lives in InstrumentRegistry.
    private static func projectKind(
        kindID: String,
        stateJSON: String,
        definitionJSON: String
    ) -> InstrumentDisplay? {
        guard let stateObj = jsonObject(from: stateJSON) else { return nil }
        let defObj = jsonObject(from: definitionJSON) ?? [:]
        guard let kind = DisplayKind(rawValue: kindID) else {
            return InstrumentDisplay.unreadable
        }
        switch kind {
        case .runningAccumulator:
            return projectRunningAccumulator(state: stateObj, definition: defObj)
        case .boundedBudget:
            return projectBoundedBudget(state: stateObj, definition: defObj)
        case .rollingAverage:
            return projectRollingAverage(state: stateObj, definition: defObj)
        case .countdownCommitment:
            return projectCountdownCommitment(state: stateObj, definition: defObj)
        case .weeklyEvidenceLog:
            return projectWeeklyEvidenceLog(state: stateObj, definition: defObj)
        case .checklist:
            return projectChecklist(state: stateObj, definition: defObj)
        case .boundedWindow:
            return projectBoundedWindow(state: stateObj, definition: defObj)
        }
    }

    // MARK: - Kind projectors (tolerant — missing keys → nil, never crash)

    private static func projectRunningAccumulator(
        state: [String: Any], definition: [String: Any]
    ) -> InstrumentDisplay {
        let today = number(state["today_total"] ?? state["total"] ?? state["value"]) ?? 0
        let yesterday = number(state["yesterday_total"] ?? state["prev_total"])
        let unit = definition["unit"] as? String
        let primary = formatNumber(today)
        let delta = deltaLine(current: today, prior: yesterday, label: "vs yesterday")
        return InstrumentDisplay(primary: primary, unit: unit, delta: delta, staleLabel: nil)
    }

    private static func projectBoundedBudget(
        state: [String: Any], definition: [String: Any]
    ) -> InstrumentDisplay {
        let used = number(state["used"] ?? state["spent"] ?? state["current"]) ?? 0
        let limit = number(state["limit"] ?? definition["limit"]) ?? 0
        let unitRaw = definition["unit"] as? String ?? "$"
        let primary = "\(formatCurrency(used, symbol: unitRaw)) / \(formatCurrency(limit, symbol: unitRaw))"
        let daysLeft = state["days_left_in_window"] as? Int ?? state["days_remaining"] as? Int
        let deltaText: String = {
            if let d = daysLeft { return "\(d) days left in window" }
            return "this week"
        }()
        return InstrumentDisplay(
            primary: primary,
            unit: nil,
            delta: .neutral(text: deltaText),
            staleLabel: nil
        )
    }

    private static func projectRollingAverage(
        state: [String: Any], definition: [String: Any]
    ) -> InstrumentDisplay {
        let avg = number(state["rolling_average"] ?? state["average"] ?? state["value"]) ?? 0
        let yesterday = number(state["yesterday_average"] ?? state["prev_average"])
        let unit = definition["unit"] as? String
        return InstrumentDisplay(
            primary: formatNumber(avg),
            unit: unit,
            delta: deltaLine(current: avg, prior: yesterday, label: "vs yesterday"),
            staleLabel: nil
        )
    }

    private static func projectCountdownCommitment(
        state: [String: Any], definition: [String: Any]
    ) -> InstrumentDisplay {
        let done = state["done_count"] as? Int ?? 0
        let target = (state["target"] as? Int) ?? (definition["target"] as? Int) ?? 0
        let daysLeft = state["days_remaining"] as? Int
        let delta: InstrumentDisplay.DeltaLine = daysLeft.map {
            .neutral(text: "\($0) left in window")
        } ?? .none
        return InstrumentDisplay(
            primary: "\(done) / \(target)",
            unit: nil,
            delta: delta,
            staleLabel: nil
        )
    }

    private static func projectWeeklyEvidenceLog(
        state: [String: Any], definition: [String: Any]
    ) -> InstrumentDisplay {
        let count = state["this_week_count"] as? Int ?? state["count"] as? Int ?? 0
        let last = state["last_week_count"] as? Int
        let delta: InstrumentDisplay.DeltaLine
        if let l = last {
            let diff = count - l
            if diff > 0 { delta = .improvement(text: "vs last week: +\(diff)") }
            else if diff < 0 { delta = .worse(text: "vs last week: \(diff)") }
            else { delta = .neutral(text: "vs last week: 0") }
        } else {
            delta = .neutral(text: "this week")
        }
        return InstrumentDisplay(
            primary: "\(count) this week",
            unit: nil,
            delta: delta,
            staleLabel: nil
        )
    }

    private static func projectChecklist(
        state: [String: Any], definition: [String: Any]
    ) -> InstrumentDisplay {
        let checked = (state["checked_today"] as? Int)
            ?? ((state["items_checked_today"] as? [Any])?.count)
            ?? 0
        let total = (state["total_items"] as? Int)
            ?? ((definition["items"] as? [Any])?.count)
            ?? 0
        let primary = "\(checked) / \(total) today"
        // §2.3 banned streak language — show "{N} checked today" instead.
        return InstrumentDisplay(
            primary: primary,
            unit: nil,
            delta: .neutral(text: "\(checked) checked today"),
            staleLabel: nil
        )
    }

    private static func projectBoundedWindow(
        state: [String: Any], definition: [String: Any]
    ) -> InstrumentDisplay {
        let pct = number(state["compliance_pct"] ?? state["in_window_pct"]) ?? 0
        let inWindow = state["in_window_count"] as? Int ?? 0
        let windowSize = (definition["window_size"] as? Int) ?? (state["window_size"] as? Int) ?? 7
        let primary = "\(Int(pct.rounded()))%"
        return InstrumentDisplay(
            primary: primary,
            unit: nil,
            delta: .neutral(text: "\(inWindow) of last \(windowSize) in window"),
            staleLabel: nil
        )
    }

    // MARK: - Helpers

    private static func jsonObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func number(_ any: Any?) -> Double? {
        guard let any else { return nil }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func formatNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1_000_000 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private static func formatCurrency(_ value: Double, symbol: String) -> String {
        let s = String(format: "%.0f", value)
        return "\(symbol)\(s)"
    }

    private static func deltaLine(
        current: Double, prior: Double?, label: String
    ) -> InstrumentDisplay.DeltaLine {
        guard let prior else { return .none }
        let diff = current - prior
        if diff == 0 { return .neutral(text: "\(label): 0") }
        let pct = prior == 0 ? 1.0 : abs(diff / prior)
        if pct < 0.05 {
            return .neutral(text: "\(label): \(diff > 0 ? "+" : "")\(formatNumber(diff))")
        }
        if diff > 0 {
            return .improvement(text: "\(label): +\(formatNumber(diff))")
        }
        return .worse(text: "\(label): \(formatNumber(diff))")
    }

    private static func staleLabel(lastUpdatedAt: Date, now: Date) -> String? {
        let hours = now.timeIntervalSince(lastUpdatedAt) / 3600
        guard hours >= 48 else { return nil }
        let days = Int((hours / 24).rounded(.down))
        return "last logged \(days)d ago"
    }
}
