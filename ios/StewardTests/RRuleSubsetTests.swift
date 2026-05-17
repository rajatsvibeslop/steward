//
//  RRuleSubsetTests.swift
//  StewardTests
//
//  Verifies the RFC 5545 RRULE subset parser + the expansion logic in
//  RecurringExpander.
//

import XCTest
@testable import Steward

final class RRuleSubsetTests: XCTestCase {

    // MARK: - Parser

    func testParseDailyMorningBriefRule() throws {
        let rule = try RRuleParser.parse("FREQ=DAILY;BYHOUR=7;BYMINUTE=0")
        XCTAssertEqual(rule.frequency, .daily)
        XCTAssertEqual(rule.byHour, 7)
        XCTAssertEqual(rule.byMinute, 0)
        XCTAssertTrue(rule.byDay.isEmpty)
    }

    func testParseWeekdayOnlyRule() throws {
        let rule = try RRuleParser.parse("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=30")
        XCTAssertEqual(rule.byDay, [.monday, .tuesday, .wednesday, .thursday, .friday])
        XCTAssertEqual(rule.byHour, 9)
        XCTAssertEqual(rule.byMinute, 30)
    }

    func testParseAcceptsLeadingRRULEPrefix() throws {
        let rule = try RRuleParser.parse("RRULE:FREQ=DAILY;BYHOUR=22;BYMINUTE=30")
        XCTAssertEqual(rule.byHour, 22)
    }

    func testParseRejectsUnsupportedFrequency() {
        XCTAssertThrowsError(try RRuleParser.parse("FREQ=WEEKLY;BYHOUR=7;BYMINUTE=0")) { e in
            guard case RRuleParseError.unsupportedFrequency = e else {
                return XCTFail("expected unsupportedFrequency, got \(e)")
            }
        }
    }

    func testParseRejectsUnsupportedKey() {
        XCTAssertThrowsError(try RRuleParser.parse("FREQ=DAILY;COUNT=5;BYHOUR=7;BYMINUTE=0")) { e in
            guard case RRuleParseError.unsupportedKey(let k) = e else {
                return XCTFail("expected unsupportedKey, got \(e)")
            }
            XCTAssertEqual(k, "COUNT")
        }
    }

    func testParseRejectsHourOutOfRange() {
        XCTAssertThrowsError(try RRuleParser.parse("FREQ=DAILY;BYHOUR=25;BYMINUTE=0")) { e in
            guard case RRuleParseError.invalidHour = e else {
                return XCTFail("expected invalidHour, got \(e)")
            }
        }
    }

    func testParseRejectsInvalidWeekday() {
        XCTAssertThrowsError(try RRuleParser.parse("FREQ=DAILY;BYDAY=XX;BYHOUR=7;BYMINUTE=0")) { e in
            guard case RRuleParseError.invalidWeekday = e else {
                return XCTFail("expected invalidWeekday, got \(e)")
            }
        }
    }

    func testParseRejectsMissingByHour() {
        XCTAssertThrowsError(try RRuleParser.parse("FREQ=DAILY;BYMINUTE=0")) { e in
            guard case RRuleParseError.missingByHour = e else {
                return XCTFail("expected missingByHour, got \(e)")
            }
        }
    }

    // MARK: - Date component expansion

    func testDailyRuleProducesSingleDateComponents() throws {
        let rule = try RRuleParser.parse("FREQ=DAILY;BYHOUR=7;BYMINUTE=0")
        let comps = RRuleParser.dateComponents(for: rule)
        XCTAssertEqual(comps.count, 1)
        XCTAssertEqual(comps[0].hour, 7)
        XCTAssertEqual(comps[0].minute, 0)
        XCTAssertNil(comps[0].weekday)
    }

    func testWeekdayRuleProducesOneTriggerPerWeekday() throws {
        let rule = try RRuleParser.parse("FREQ=DAILY;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=30")
        let comps = RRuleParser.dateComponents(for: rule)
        XCTAssertEqual(comps.count, 3)
        let weekdays = comps.compactMap(\.weekday).sorted()
        // MO=2, WE=4, FR=6
        XCTAssertEqual(weekdays, [2, 4, 6])
        for c in comps {
            XCTAssertEqual(c.hour, 9)
            XCTAssertEqual(c.minute, 30)
        }
    }

    func testRecurringExpansion7DaysOfMorningBrief() throws {
        let rule = try RRuleParser.parse("FREQ=DAILY;BYHOUR=7;BYMINUTE=0")
        let tz = TimeZone(identifier: "America/New_York")!

        // Anchor at a known-good moment so the test is reproducible.
        var anchor = DateComponents()
        anchor.year = 2026; anchor.month = 5; anchor.day = 17; anchor.hour = 0; anchor.minute = 5
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let anchorDate = cal.date(from: anchor)!

        let occurrences = RecurringExpander.nextOccurrences(
            rule: rule, startingAt: anchorDate, daysAhead: 7, timeZone: tz
        )
        XCTAssertEqual(occurrences.count, 7)

        // Every occurrence should be at 7:00 local.
        for occ in occurrences {
            let comps = cal.dateComponents([.hour, .minute], from: occ)
            XCTAssertEqual(comps.hour, 7)
            XCTAssertEqual(comps.minute, 0)
        }
        // First one is today (May 17), 7am.
        let first = cal.dateComponents([.year, .month, .day, .hour], from: occurrences[0])
        XCTAssertEqual(first.year, 2026)
        XCTAssertEqual(first.month, 5)
        XCTAssertEqual(first.day, 17)
        XCTAssertEqual(first.hour, 7)
    }

    func testRecurringExpansionWeekdaysOnlySkipsWeekend() throws {
        let rule = try RRuleParser.parse("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0")
        let tz = TimeZone(identifier: "America/New_York")!

        // 2026-05-17 is a Sunday in NYC.
        var anchor = DateComponents()
        anchor.year = 2026; anchor.month = 5; anchor.day = 17; anchor.hour = 0; anchor.minute = 5
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let anchorDate = cal.date(from: anchor)!

        let occurrences = RecurringExpander.nextOccurrences(
            rule: rule, startingAt: anchorDate, daysAhead: 10, timeZone: tz
        )
        // Should hit Mon-Fri (May 18,19,20,21,22) and Mon-Fri (May 25,26).
        // Skip Sat (May 23), Sun (May 24).
        let dayMonths = occurrences.map {
            let c = cal.dateComponents([.month, .day], from: $0)
            return "\(c.month!)/\(c.day!)"
        }
        XCTAssertTrue(dayMonths.contains("5/18"))
        XCTAssertFalse(dayMonths.contains("5/23"))
        XCTAssertFalse(dayMonths.contains("5/24"))
    }
}
