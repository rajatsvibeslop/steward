//
//  RRuleSubset.swift
//  Steward
//
//  RFC 5545 RRULE subset → UNCalendarNotificationTrigger translation.
//
//  Supported: FREQ=DAILY, BYHOUR, BYMINUTE, BYDAY (MO,TU,WE,TH,FR,SA,SU).
//  Unsupported: COUNT, UNTIL, INTERVAL > 1, FREQ != DAILY, BYMONTH, BYMONTHDAY,
//  BYSETPOS, WKST. Unsupported keys raise an explicit error rather than
//  silently dropping — agent prompts will be updated to stay in the subset.
//
//  Per spec §10 #2: a daily-morning-brief rule becomes ONE UNNotificationRequest
//  with `UNCalendarNotificationTrigger(repeats: true)`. Multi-BYDAY rules
//  become one trigger per weekday (each repeats weekly). This file knows how
//  to fan a rule out into the minimal trigger set; cap/quiet-hours logic
//  lives in NotificationScheduler.
//

import Foundation

struct RRuleSubset: Sendable, Codable, Equatable {
    enum Frequency: String, Codable, Sendable {
        case daily = "DAILY"
    }
    enum Weekday: String, Codable, Sendable, CaseIterable {
        case monday = "MO", tuesday = "TU", wednesday = "WE",
             thursday = "TH", friday = "FR", saturday = "SA", sunday = "SU"

        /// Calendar weekday number (Sun = 1, Sat = 7) — what `DateComponents`
        /// expects. Note: this is Gregorian Calendar's default, which matches
        /// what `UNCalendarNotificationTrigger` reads.
        var calendarWeekday: Int {
            switch self {
            case .sunday: return 1
            case .monday: return 2
            case .tuesday: return 3
            case .wednesday: return 4
            case .thursday: return 5
            case .friday: return 6
            case .saturday: return 7
            }
        }
    }

    let frequency: Frequency
    /// Empty array means "any weekday" (effectively daily).
    let byDay: [Weekday]
    /// One BYHOUR value supported (RFC allows lists; we collapse to first).
    let byHour: Int
    let byMinute: Int

    init(frequency: Frequency, byDay: [Weekday], byHour: Int, byMinute: Int) {
        self.frequency = frequency
        self.byDay = byDay
        self.byHour = byHour
        self.byMinute = byMinute
    }
}

enum RRuleParseError: Error, CustomStringConvertible, Equatable {
    case malformedRule(String)
    case unsupportedFrequency(String)
    case unsupportedKey(String)
    case invalidHour(Int)
    case invalidMinute(Int)
    case invalidWeekday(String)
    case missingByHour
    case missingByMinute

    var description: String {
        switch self {
        case .malformedRule(let s): return "Malformed RRULE: \(s)"
        case .unsupportedFrequency(let f): return "Unsupported FREQ=\(f). Only FREQ=DAILY supported."
        case .unsupportedKey(let k): return "Unsupported RRULE key: \(k)"
        case .invalidHour(let h): return "BYHOUR out of range (0..23): \(h)"
        case .invalidMinute(let m): return "BYMINUTE out of range (0..59): \(m)"
        case .invalidWeekday(let s): return "Invalid BYDAY value: \(s). Use MO,TU,WE,TH,FR,SA,SU."
        case .missingByHour: return "RRULE missing BYHOUR."
        case .missingByMinute: return "RRULE missing BYMINUTE."
        }
    }
}

enum RRuleParser {
    /// Parse a single RRULE line. Leading "RRULE:" prefix is optional.
    /// Whitespace is trimmed. Keys are case-insensitive; values follow RFC 5545.
    static func parse(_ raw: String) throws -> RRuleSubset {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.uppercased().hasPrefix("RRULE:") {
            input = String(input.dropFirst("RRULE:".count))
        }
        guard !input.isEmpty else { throw RRuleParseError.malformedRule(raw) }

        var freq: RRuleSubset.Frequency?
        var byDay: [RRuleSubset.Weekday] = []
        var byHour: Int?
        var byMinute: Int?

        for part in input.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { throw RRuleParseError.malformedRule(raw) }
            let key = kv[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "FREQ":
                guard let f = RRuleSubset.Frequency(rawValue: value.uppercased()) else {
                    throw RRuleParseError.unsupportedFrequency(value)
                }
                freq = f
            case "BYHOUR":
                // RFC allows comma-separated list; we collapse to first.
                let head = value.split(separator: ",").first.map(String.init) ?? value
                guard let h = Int(head), (0...23).contains(h) else {
                    throw RRuleParseError.invalidHour(Int(head) ?? -1)
                }
                byHour = h
            case "BYMINUTE":
                let head = value.split(separator: ",").first.map(String.init) ?? value
                guard let m = Int(head), (0...59).contains(m) else {
                    throw RRuleParseError.invalidMinute(Int(head) ?? -1)
                }
                byMinute = m
            case "BYDAY":
                var weekdays: [RRuleSubset.Weekday] = []
                for token in value.split(separator: ",") {
                    let normalized = token.trimmingCharacters(in: .whitespaces).uppercased()
                    // Reject prefixes like "2MO" (positional BYDAY) since we
                    // don't support BYSETPOS; let the agent retry with a
                    // simpler rule.
                    guard let wd = RRuleSubset.Weekday(rawValue: normalized) else {
                        throw RRuleParseError.invalidWeekday(normalized)
                    }
                    weekdays.append(wd)
                }
                byDay = weekdays
            case "COUNT", "UNTIL", "INTERVAL", "BYMONTH", "BYMONTHDAY", "BYSETPOS", "WKST", "BYYEARDAY", "BYWEEKNO":
                throw RRuleParseError.unsupportedKey(key)
            default:
                throw RRuleParseError.unsupportedKey(key)
            }
        }

        guard let resolvedFreq = freq else {
            throw RRuleParseError.unsupportedFrequency("(missing)")
        }
        guard let resolvedHour = byHour else { throw RRuleParseError.missingByHour }
        guard let resolvedMinute = byMinute else { throw RRuleParseError.missingByMinute }

        return RRuleSubset(
            frequency: resolvedFreq,
            byDay: byDay,
            byHour: resolvedHour,
            byMinute: resolvedMinute
        )
    }

    /// Fan a rule out into the minimal trigger set:
    /// - daily (empty byDay) → single trigger that repeats daily.
    /// - daily with byDay=[MO,FR] → two triggers, each weekly-repeating.
    ///
    /// Returns the `DateComponents` per trigger so the caller can construct
    /// `UNCalendarNotificationTrigger(dateMatching:repeats:)`. Pure function;
    /// safe to test without UserNotifications symbols.
    static func dateComponents(for rule: RRuleSubset) -> [DateComponents] {
        if rule.byDay.isEmpty {
            var comps = DateComponents()
            comps.hour = rule.byHour
            comps.minute = rule.byMinute
            return [comps]
        }
        return rule.byDay
            .map { day -> DateComponents in
                var comps = DateComponents()
                comps.hour = rule.byHour
                comps.minute = rule.byMinute
                comps.weekday = day.calendarWeekday
                return comps
            }
    }

}
