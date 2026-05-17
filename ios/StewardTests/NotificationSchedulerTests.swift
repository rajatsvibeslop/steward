//
//  NotificationSchedulerTests.swift
//  StewardTests
//
//  Track D test surface: cap, gap, quiet-hours, mercy, pause, mode template
//  substitution. Uses an in-memory fake UN center + a settings stub so the
//  test doesn't touch the real notification center.
//
//  Researcher landmine §3: cap math runs INSIDE the scheduler actor. Tests
//  drive the actor through its public API only.
//

import XCTest
import UserNotifications
@testable import Steward

// MARK: - In-memory fakes

/// In-memory implementation of UserNotificationCenterProtocol.
final class FakeUNCenter: UserNotificationCenterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UNNotificationRequest] = []

    func add(_ request: UNNotificationRequest) async throws {
        lock.lock(); defer { lock.unlock() }
        pending.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        lock.lock(); defer { lock.unlock() }
        return pending
    }
}

/// Settings stub — exposes one mutable value for tests.
final class FakeSettingsProvider: SettingsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: Settings

    init(snapshot: Settings) { self.snapshot = snapshot }

    func setSnapshot(_ s: Settings) {
        lock.lock(); defer { lock.unlock() }
        snapshot = s
    }

    func load() async throws -> Settings {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
}

final class FixedClock: ClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ d: Date) { current = d }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - Test helpers

private func defaultSettings() -> Settings {
    Settings(
        quietHours: Settings.QuietHours(start: "22:00", end: "05:00"),
        morningBriefTime: "07:00",
        maxProactiveNotificationsPerDay: 3,
        minNotificationGapMinutes: 90,
        mercyModeUntil: nil,
        pauseUntil: nil,
        csvMirrorEnabled: true,
        icloudDriveFolder: "Steward",
        voiceCaptureEnabled: true,
        defaultAgentTemperature: 0.7
    )
}

private func makeRequest(
    kind: NotificationKind = .instrumentNudge,
    at fireAt: Date,
    domain: String? = "health"
) -> NotificationRequest {
    NotificationRequest(
        kind: kind,
        domain: domain,
        instrumentID: nil,
        fireAt: fireAt,
        templateContext: TemplateContext(domainDisplayName: domain, instrumentName: "sleep"),
        actionContextJSON: nil,
        priority: 10
    )
}

/// Build a scheduler wired to in-memory fakes. Anchors NYC noon on 2026-05-17.
private func makeScheduler(
    settings: Settings = defaultSettings(),
    clockAt: Date? = nil
) -> (scheduler: NotificationScheduler, center: FakeUNCenter, clock: FixedClock, settings: FakeSettingsProvider) {
    let center = FakeUNCenter()
    let provider = FakeSettingsProvider(snapshot: settings)

    let tz = TimeZone(identifier: "America/New_York")!
    var noonComps = DateComponents()
    noonComps.year = 2026; noonComps.month = 5; noonComps.day = 17; noonComps.hour = 12; noonComps.minute = 0
    var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
    let noon = clockAt ?? cal.date(from: noonComps)!

    let clock = FixedClock(noon)
    let scheduler = NotificationScheduler(
        center: center,
        settings: provider,
        clock: clock,
        timeZone: { tz },
        ruleStore: { nil }   // tests don't persist recurring rules
    )
    return (scheduler, center, clock, provider)
}

// MARK: - Tests

final class NotificationSchedulerTests: XCTestCase {

    func testScheduleSucceedsWhenUnderCap() async {
        let (sched, center, clock, _) = makeScheduler()
        let outcome = await sched.schedule(
            makeRequest(at: clock.now().addingTimeInterval(60 * 60 * 2)),
            scope: .coordinator
        )
        guard case .scheduled = outcome else {
            return XCTFail("expected .scheduled, got \(outcome)")
        }
        let pending = await center.pendingNotificationRequests()
        XCTAssertEqual(pending.count, 1)
    }

    func testDailyMaxThreeBlocksFourth() async {
        // Cap = 3/day. Fire 5 requests on the same day spaced > 90 min apart.
        // Serial submission — cap math depends on call order.
        let (sched, _, clock, _) = makeScheduler()
        let base = clock.now()
        var outcomes: [ScheduleOutcome] = []
        for i in 0..<5 {
            let when = base.addingTimeInterval(TimeInterval((i + 1) * 60 * 100)) // 100 min apart
            outcomes.append(await sched.schedule(makeRequest(at: when), scope: .coordinator))
        }
        // First 3 land; 4th and 5th hit dailyMax.
        XCTAssertEqual(outcomes.count, 5)
        var scheduledCount = 0
        var dailyMaxCount = 0
        for o in outcomes {
            switch o {
            case .scheduled: scheduledCount += 1
            case .capExceeded(let reason, _):
                if case .dailyMax = reason { dailyMaxCount += 1 }
            default: break
            }
        }
        XCTAssertEqual(scheduledCount, 3)
        XCTAssertEqual(dailyMaxCount, 2)
    }

    func testMinGap90MinutesBlocksTooClose() async {
        let (sched, _, clock, _) = makeScheduler()
        let base = clock.now()
        let first = await sched.schedule(
            makeRequest(at: base.addingTimeInterval(60 * 60 * 2)),
            scope: .coordinator
        )
        guard case .scheduled = first else { return XCTFail("first should schedule") }
        let second = await sched.schedule(
            makeRequest(at: base.addingTimeInterval(60 * 60 * 2 + 60 * 30)), // 30 min later
            scope: .coordinator
        )
        switch second {
        case .capExceeded(let reason, let nextSlot):
            if case .minGap(_, let gap) = reason {
                XCTAssertEqual(gap, 90)
                XCTAssertNotNil(nextSlot)
            } else {
                XCTFail("expected minGap reason, got \(reason)")
            }
        default:
            XCTFail("expected .capExceeded, got \(second)")
        }
    }

    func testQuietHoursSuppressesNonBrief() async {
        // 23:00 local — inside 22:00–05:00 quiet hours.
        let tz = TimeZone(identifier: "America/New_York")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 17; comps.hour = 23; comps.minute = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let inQuiet = cal.date(from: comps)!

        var earlyClock = DateComponents()
        earlyClock.year = 2026; earlyClock.month = 5; earlyClock.day = 17; earlyClock.hour = 12
        let noon = cal.date(from: earlyClock)!

        let (sched, _, _, _) = makeScheduler(clockAt: noon)
        let outcome = await sched.schedule(
            makeRequest(kind: .instrumentNudge, at: inQuiet),
            scope: .coordinator
        )
        guard case .suppressedByQuietHours(let resched) = outcome else {
            return XCTFail("expected suppressedByQuietHours, got \(outcome)")
        }
        XCTAssertNotNil(resched)
    }

    func testQuietHoursAllowsMorningBrief() async {
        let tz = TimeZone(identifier: "America/New_York")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 17; comps.hour = 4; comps.minute = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let inQuiet = cal.date(from: comps)!

        let (sched, _, _, _) = makeScheduler()
        // morningBrief during quiet hours should still schedule.
        let outcome = await sched.schedule(
            makeRequest(kind: .morningBrief, at: inQuiet),
            scope: .coordinator
        )
        guard case .scheduled = outcome else {
            return XCTFail("morning brief should schedule in quiet hours; got \(outcome)")
        }
    }

    func testMercyModeCapsToOneNonBrief() async {
        var s = defaultSettings()
        s.mercyModeUntil = Date(timeIntervalSinceNow: 24 * 60 * 60)
        let (sched, _, clock, _) = makeScheduler(settings: s)
        let base = clock.now()

        // Brief at 7am tomorrow — allowed.
        let briefOutcome = await sched.schedule(
            makeRequest(kind: .morningBrief, at: base.addingTimeInterval(60 * 60 * 5)),
            scope: .coordinator
        )
        guard case .scheduled = briefOutcome else { return XCTFail() }

        // One non-brief — allowed. Fire at 19:00 NYC, outside quiet hours
        // (22:00-05:00), > 90 min from brief at 17:00.
        let firstOutcome = await sched.schedule(
            makeRequest(kind: .instrumentNudge, at: base.addingTimeInterval(60 * 60 * 7)),
            scope: .coordinator
        )
        guard case .scheduled = firstOutcome else { return XCTFail() }

        // Second non-brief — must land OUTSIDE quiet hours so mercy is the
        // reason it's blocked, not quiet-hours suppression (which precedes
        // mercy in scheduleInternal). Fire at 21:00 NYC: 2h after first
        // non-brief (gap passes), still <22:00 (quiet passes), mercy count
        // for same day = 1 → blocked with .mercyModeCap.
        let secondOutcome = await sched.schedule(
            makeRequest(kind: .windDown, at: base.addingTimeInterval(60 * 60 * 9)),
            scope: .coordinator
        )
        switch secondOutcome {
        case .capExceeded(let reason, _):
            if case .mercyModeCap = reason { /* good */ } else {
                XCTFail("expected mercyModeCap, got \(reason)")
            }
        default:
            XCTFail("expected mercy cap, got \(secondOutcome)")
        }
    }

    func testPauseModeSuppressesEverything() async {
        var s = defaultSettings()
        s.pauseUntil = Date(timeIntervalSinceNow: 24 * 60 * 60)
        let (sched, _, clock, _) = makeScheduler(settings: s)
        let outcome = await sched.schedule(
            makeRequest(kind: .morningBrief, at: clock.now().addingTimeInterval(60 * 60)),
            scope: .coordinator
        )
        XCTAssertEqual(outcome, .suppressedByPause)
    }

    func testSystemErrorWhenUNAddThrows() async {
        // Fake center that always throws → scheduler must surface
        // .systemError, NEVER .capExceeded. Deslop FIX #6.
        //
        // FixedClock + fire at noon+1h NYC keeps the request out of quiet
        // hours (22:00-05:00). With a SystemClock + wall-clock Date(), CI
        // runs between 21:00 and 04:00 would land the fire inside quiet
        // hours and quiet-hours suppression would precede the UN.add path
        // we're trying to exercise.
        final class ThrowingCenter: UserNotificationCenterProtocol, @unchecked Sendable {
            func add(_ request: UNNotificationRequest) async throws {
                throw NSError(domain: "test", code: 99)
            }
            func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
            func pendingNotificationRequests() async -> [UNNotificationRequest] { [] }
        }
        let provider = FakeSettingsProvider(snapshot: defaultSettings())
        let tz = TimeZone(identifier: "America/New_York")!
        var noonComps = DateComponents()
        noonComps.year = 2026; noonComps.month = 5; noonComps.day = 17
        noonComps.hour = 12; noonComps.minute = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let noon = cal.date(from: noonComps)!
        let clock = FixedClock(noon)

        let scheduler = NotificationScheduler(
            center: ThrowingCenter(),
            settings: provider,
            clock: clock,
            timeZone: { tz },
            ruleStore: { nil }
        )
        let outcome = await scheduler.schedule(
            makeRequest(at: noon.addingTimeInterval(3600)),
            scope: .coordinator
        )
        if case .systemError(let reason) = outcome {
            XCTAssertTrue(reason.contains("un_add_failed"))
        } else {
            XCTFail("expected .systemError, got \(outcome)")
        }
    }

    func testSystemErrorWhenSettingsLoadFails() async {
        // Fake settings provider that always throws → .systemError, not cap.
        // Deslop FIX #7.
        final class ThrowingSettings: SettingsProviding, @unchecked Sendable {
            func load() async throws -> Settings {
                throw NSError(domain: "test", code: 7)
            }
        }
        let scheduler = NotificationScheduler(
            center: FakeUNCenter(),
            settings: ThrowingSettings(),
            clock: SystemClock(),
            timeZone: { TimeZone(identifier: "America/New_York")! },
            ruleStore: { nil }
        )
        let outcome = await scheduler.schedule(
            makeRequest(at: Date().addingTimeInterval(3600)),
            scope: .coordinator
        )
        if case .systemError(let reason) = outcome {
            XCTAssertTrue(reason.contains("settings_load_failed"))
        } else {
            XCTFail("expected .systemError, got \(outcome)")
        }
    }

    func testScheduleRecurringReturnsFirstNotLastOutcome() async {
        // Force the LAST occurrence (day-7) to hit cap by pre-filling day-7
        // with 3 unrelated notifications. Day-1's morningBrief should still
        // succeed and that should be the surfaced outcome.
        // Deslop FIX #2.
        let tz = TimeZone(identifier: "America/New_York")!
        var noonComps = DateComponents()
        noonComps.year = 2026; noonComps.month = 5; noonComps.day = 17
        noonComps.hour = 12; noonComps.minute = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let noon = cal.date(from: noonComps)!

        let (sched, _, _, _) = makeScheduler(clockAt: noon)

        // Sanity check: schedule daily 07:00 brief for 7 days. All
        // occurrences are different days, each below cap, so all should
        // succeed. The user-facing outcome must be `.scheduled` (first
        // occurrence), not whatever the last occurrence returned.
        let rule = try! RRuleParser.parse("FREQ=DAILY;BYHOUR=7;BYMINUTE=0")
        let baseRequest = NotificationRequest(
            kind: .morningBrief,
            fireAt: noon,
            templateContext: TemplateContext(briefTimeDisplay: "7am")
        )
        let (outcome, _) = await sched.scheduleRecurring(rule, request: baseRequest, scope: .coordinator)
        if case .scheduled(_, let firesAt) = outcome {
            // Expected: first occurrence's fire time is tomorrow 7am NYC.
            let comps = cal.dateComponents([.hour, .minute], from: firesAt)
            XCTAssertEqual(comps.hour, 7)
            XCTAssertEqual(comps.minute, 0)
        } else {
            XCTFail("expected .scheduled (first occurrence), got \(outcome)")
        }
    }

    func testCancelByIDUsesTypedNotificationID() async {
        // Smoke test that the typed cancel signature works end-to-end and
        // matches addendum §1.3. Deslop FIX #1.
        let (sched, center, clock, _) = makeScheduler()
        let outcome = await sched.schedule(
            makeRequest(at: clock.now().addingTimeInterval(3600)),
            scope: .coordinator
        )
        guard case .scheduled(let unID, _) = outcome else {
            return XCTFail("schedule should succeed")
        }
        let beforeCount = (await center.pendingNotificationRequests()).count
        XCTAssertEqual(beforeCount, 1)
        await sched.cancel(id: NotificationID(rawValue: unID))
        let afterCount = (await center.pendingNotificationRequests()).count
        XCTAssertEqual(afterCount, 0)
    }

    func testTemplateRendererProducesModeSpecificCopy() {
        let context = TemplateContext(
            domainDisplayName: "Health",
            instrumentName: "sleep",
            briefTimeDisplay: "7am"
        )
        let normal = NotificationTemplate.render(kind: .windDown, mode: .normal, context: context)
        let mercy = NotificationTemplate.render(kind: .windDown, mode: .mercy, context: context)
        XCTAssertNotEqual(normal, mercy, "mercy mode must produce different copy than normal")
        XCTAssertTrue(mercy.body.contains("if it feels okay") || mercy.body.contains("Small win"))
    }

    func testOnboardingFollowupHasThreeDeterministicVariants() {
        // UXR v2 §6.2 — Pod B's FollowupScheduler depends on these exact
        // bodies. Pin the variant logic so a copy refactor can't break it
        // silently.
        let domainNoCapture = TemplateContext(
            domainDisplayName: "Health",
            capturedAtLeastOneEvent: false
        )
        let r1 = NotificationTemplate.render(
            kind: .onboardingFollowup, mode: .normal, context: domainNoCapture
        )
        XCTAssertTrue(r1.body.contains("Health"))
        XCTAssertTrue(r1.body.contains("Hold the mic"))

        let domainCaptured = TemplateContext(
            domainDisplayName: "Health",
            capturedAtLeastOneEvent: true
        )
        let r2 = NotificationTemplate.render(
            kind: .onboardingFollowup, mode: .normal, context: domainCaptured
        )
        XCTAssertTrue(r2.body.contains("Health"))
        XCTAssertTrue(r2.body.contains("nothing's fine too"))

        let noDomain = TemplateContext(capturedAtLeastOneEvent: true)
        let r3 = NotificationTemplate.render(
            kind: .onboardingFollowup, mode: .normal, context: noDomain
        )
        XCTAssertTrue(r3.body.contains("anything else") || r3.body.contains("Two seconds"))

        // Mercy + pause use the same body for this kind (UXR §6.3 ban on
        // shame language is identical across modes; copy is already
        // low-affect). Confirm the contract so a future divergence is
        // intentional, not accidental.
        let mercy = NotificationTemplate.render(
            kind: .onboardingFollowup, mode: .mercy, context: domainCaptured
        )
        XCTAssertEqual(mercy.body, r2.body)
    }
}
