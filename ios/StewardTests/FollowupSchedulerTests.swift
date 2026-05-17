//
//  FollowupSchedulerTests.swift
//  StewardTests — Track B
//
//  Pure-helper coverage of the day-0 followup scheduler. Body copy,
//  fire-time window clamp, skip-no-engagement logic.
//

import XCTest
@testable import Steward

final class FollowupSchedulerTests: XCTestCase {

    private let nyc = TimeZone(identifier: "America/New_York")!

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = nyc
        return cal.date(from: comps)!
    }

    // MARK: - Fire-time window

    func test_fireTime_insideWindow_unchanged() {
        // 9am + 5h30m = 14:30, inside [13:00, 17:00]
        let now = date(2026, 5, 17, 9, 0)
        let fire = FollowupScheduler.computeFireTime(now: now, timezone: nyc)
        XCTAssertNotNil(fire)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = nyc
        let comps = cal.dateComponents([.hour, .minute], from: fire!)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 30)
    }

    func test_fireTime_beforeWindow_snapsTo13() {
        // 6am + 5h30m = 11:30, before 13:00 → snap to 13:00
        let now = date(2026, 5, 17, 6, 0)
        let fire = FollowupScheduler.computeFireTime(now: now, timezone: nyc)
        XCTAssertNotNil(fire)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = nyc
        let comps = cal.dateComponents([.hour, .minute], from: fire!)
        XCTAssertEqual(comps.hour, 13)
        XCTAssertEqual(comps.minute, 0)
    }

    func test_fireTime_afterWindow_returnsNil_S3() {
        // 13:00 + 5h30m = 18:30, after 17:00 → snap to 17:00 would land in
        // the past → return nil per deslop S3.
        let now = date(2026, 5, 17, 13, 0)
        let fire = FollowupScheduler.computeFireTime(now: now, timezone: nyc)
        XCTAssertNil(fire,
                     "Past-17:00 NOW means the snapped 17:00 is in the past — must skip.")
    }

    func test_fireTime_lateEvening_returnsNil_S3() {
        // 19:00 + 5h30m = 00:30 NEXT day → past day-0's 17:00 window edge.
        // Day-0 followup belongs on day 0; rather than schedule next day's
        // 13:00, we skip per deslop S3.
        let now = date(2026, 5, 17, 19, 0)
        let fire = FollowupScheduler.computeFireTime(now: now, timezone: nyc)
        XCTAssertNil(fire,
                     "Past-17:00 of day 0 → skip; never snap forward to a different day.")
    }

    func test_fireTime_returnedDate_isAlwaysFuture() {
        // Sanity: when non-nil the returned fire time must be > now.
        let cases: [(Int, Int)] = [(6, 0), (9, 30), (10, 15), (11, 59)]
        for (h, m) in cases {
            let now = date(2026, 5, 17, h, m)
            if let fire = FollowupScheduler.computeFireTime(now: now, timezone: nyc) {
                XCTAssertGreaterThan(fire, now,
                                     "Non-nil fire time must be strictly future. h=\(h) m=\(m)")
            }
        }
    }

    // MARK: - Template copy (verbatim §6.2) — now lives in NotificationTemplate
    //
    // Body composition moved out of FollowupScheduler per deslop B2; the
    // §6.2 verbatim copy lives in NotificationTemplate's
    // .onboardingFollowup arm. These tests assert it from there.

    func test_templateCopy_spawnedDomainOnly() {
        let context = TemplateContext(
            domainDisplayName: "Health",
            capturedAtLeastOneEvent: false
        )
        let r = NotificationTemplate.render(
            kind: .onboardingFollowup,
            mode: .normal,
            context: context
        )
        XCTAssertEqual(r.title, "Steward")
        XCTAssertTrue(r.body.contains("You set up the Health team this morning"))
        XCTAssertTrue(r.body.contains("Hold the mic"))
    }

    func test_templateCopy_capturedEventOnly() {
        let context = TemplateContext(
            domainDisplayName: nil,
            capturedAtLeastOneEvent: true
        )
        let r = NotificationTemplate.render(
            kind: .onboardingFollowup, mode: .normal, context: context
        )
        XCTAssertEqual(r.body, "Anything else to catch from today? Two seconds of voice works.")
    }

    func test_templateCopy_bothDomainAndEvent() {
        let context = TemplateContext(
            domainDisplayName: "Health",
            capturedAtLeastOneEvent: true
        )
        let r = NotificationTemplate.render(
            kind: .onboardingFollowup, mode: .normal, context: context
        )
        XCTAssertTrue(r.body.contains("How's Health feeling?"))
        XCTAssertTrue(r.body.contains("nothing's fine too"))
    }

    // MARK: - Banned patterns (UXR v2 §6.3)

    func test_templateCopy_neverUsesCommitmentShameLanguage() {
        let contexts: [TemplateContext] = [
            TemplateContext(domainDisplayName: "Health", capturedAtLeastOneEvent: false),
            TemplateContext(domainDisplayName: nil, capturedAtLeastOneEvent: true),
            TemplateContext(domainDisplayName: "Money", capturedAtLeastOneEvent: true),
        ]
        for context in contexts {
            let r = NotificationTemplate.render(
                kind: .onboardingFollowup, mode: .normal, context: context
            )
            let lowered = r.body.lowercased()
            XCTAssertFalse(lowered.contains("you committed to"))
            XCTAssertFalse(lowered.contains("you said you would"))
            XCTAssertFalse(lowered.contains("don't forget"))
            XCTAssertFalse(lowered.contains("streak"))
        }
    }
}
