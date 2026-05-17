//
//  RecurringRuleStoreTests.swift
//  StewardTests
//
//  Track D fix-batch tests:
//  - RecurringRuleStore round-trips a rule and filters active vs cancelled.
//  - NotificationScheduler.topUpHorizon re-issues recurring occurrences via
//    the persisted store (deslop FIX #3: cron-via-notification correctness).
//

import XCTest
@testable import Steward

final class RecurringRuleStoreTests: XCTestCase {

    private func makeStore() async throws -> (RecurringRuleStore, DatabaseProvider, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-d-rrs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("steward-test.sqlite")
        let provider = DatabaseProvider(location: .file(url))
        _ = try await provider.database()
        return (RecurringRuleStore(provider: provider), provider, dir)
    }

    func testInsertAndLoadActiveRoundtrip() async throws {
        let (store, _, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = RecurringRuleRecord(
            rrule: "FREQ=DAILY;BYHOUR=7;BYMINUTE=0",
            kind: .morningBrief,
            domain: "health",
            templateContextJSON: "{\"briefTimeDisplay\":\"7am\"}",
            priority: 100,
            scopeActor: "coordinator"
        )
        let saved = try await store.insert(record)
        XCTAssertEqual(saved.ruleID, record.ruleID)

        let active = try await store.loadActive()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0].kind, .morningBrief)
        XCTAssertEqual(active[0].rrule, record.rrule)
        XCTAssertEqual(active[0].domain, "health")
    }

    func testCancelHidesRuleFromActive() async throws {
        let (store, _, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = RecurringRuleRecord(
            rrule: "FREQ=DAILY;BYHOUR=22;BYMINUTE=30",
            kind: .windDown,
            templateContextJSON: "{}"
        )
        _ = try await store.insert(record)
        try await store.cancel(ruleID: record.ruleID)

        let active = try await store.loadActive()
        XCTAssertTrue(active.isEmpty)
    }

    func testCancelAllByKind() async throws {
        let (store, _, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let brief = RecurringRuleRecord(
            rrule: "FREQ=DAILY;BYHOUR=7;BYMINUTE=0",
            kind: .morningBrief,
            templateContextJSON: "{}"
        )
        let nudge = RecurringRuleRecord(
            rrule: "FREQ=DAILY;BYHOUR=15;BYMINUTE=0",
            kind: .instrumentNudge,
            templateContextJSON: "{}"
        )
        _ = try await store.insert(brief)
        _ = try await store.insert(nudge)

        let cancelled = try await store.cancelAll(kind: .morningBrief)
        XCTAssertEqual(cancelled, 1)

        let active = try await store.loadActive()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0].kind, .instrumentNudge)
    }

    // MARK: - topUpHorizon re-issuance (FIX #3)

    func testTopUpHorizonReissuesPersistedRule() async throws {
        // The morning brief is the canonical case: persist a daily 07:00
        // rule, then run topUpHorizon and verify the next 7 days of UN
        // requests get registered. Without persistence + re-expansion this
        // would silently die after the initial scheduleRecurring horizon.
        let (store, provider, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Inject DEFAULT settings into the test DB so the scheduler's
        // SettingsProviding doesn't fight us. Track A's migration seeds
        // a row already, so just confirm it.
        let queue = try await provider.database()
        try await queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM settings WHERE id = 1") ?? 0
            XCTAssertEqual(count, 1, "Track A migration should seed settings row")
        }

        // Persist a daily morning-brief rule directly via the store. Skip
        // scheduleRecurring (which schedules occurrences synchronously) so
        // the test exercises ONLY the topUpHorizon re-issuance path.
        let record = RecurringRuleRecord(
            rrule: "FREQ=DAILY;BYHOUR=7;BYMINUTE=0",
            kind: .morningBrief,
            templateContextJSON: "{\"briefTimeDisplay\":\"7am\"}",
            priority: 100
        )
        _ = try await store.insert(record)

        // Wire up the scheduler with a fake UN center + live settings (from
        // Track A migration) + the test rule store.
        let center = FakeUNCenter()
        let settings = FakeSettingsProvider(snapshot: Settings(
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
        ))
        let tz = TimeZone(identifier: "America/New_York")!
        // Anchor BEFORE today's 07:00 brief so the expander includes it as
        // occurrence #1. RecurringExpander.nextOccurrences filters by
        // `fire > anchor`, so an anchor at noon would (correctly) skip
        // today's 07:00 brief and yield only 6 occurrences — that's not
        // what this test wants to exercise.
        var anchorComps = DateComponents()
        anchorComps.year = 2026; anchorComps.month = 5; anchorComps.day = 17
        anchorComps.hour = 6; anchorComps.minute = 30
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let clock = FixedClock(cal.date(from: anchorComps)!)

        let scheduler = NotificationScheduler(
            center: center,
            settings: settings,
            clock: clock,
            timeZone: { tz },
            ruleStore: { store }
        )

        await scheduler.topUpHorizon(daysAhead: 7)
        let pending = await center.pendingNotificationRequests()
        // Expect 7 morning briefs scheduled (one per day). All within cap
        // (1/day < 3/day max), gaps are 24h >> 90min. 7am morning brief is
        // exempt from the 22:00-05:00 quiet hours window.
        XCTAssertEqual(pending.count, 7, "topUpHorizon should re-issue 7 daily briefs")
    }

    // MARK: - Undo-of-schedule_recurring must not be re-issued on topUp (regression B)

    func testUndo_OfRecurringSchedule_DoesNotReissueOnTopUp() async throws {
        // Persist a recurring rule, simulate the rule getting "undone" by
        // flipping its cancelled_at via the store, then run topUpHorizon —
        // assert zero occurrences come back. This is the deslop regression B
        // pact: undoing notification.schedule_recurring must STAY undone
        // across foreground ticks.
        let (store, _, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = RecurringRuleRecord(
            rrule: "FREQ=DAILY;BYHOUR=7;BYMINUTE=0",
            kind: .morningBrief,
            templateContextJSON: "{}",
            priority: 100
        )
        _ = try await store.insert(record)

        let center = FakeUNCenter()
        let tz = TimeZone(identifier: "America/New_York")!
        // Anchor BEFORE today's 07:00 brief so the expander includes it
        // (same rationale as testTopUpHorizonReissuesPersistedRule: noon
        // would skip today's already-past 07:00).
        var anchorComps = DateComponents()
        anchorComps.year = 2026; anchorComps.month = 5; anchorComps.day = 17
        anchorComps.hour = 6; anchorComps.minute = 30
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let clock = FixedClock(cal.date(from: anchorComps)!)

        let scheduler = NotificationScheduler(
            center: center,
            settings: FakeSettingsProvider(snapshot: defaultTestSettings()),
            clock: clock,
            timeZone: { tz },
            ruleStore: { store }
        )

        // First top-up issues all 7 days as expected.
        await scheduler.topUpHorizon(daysAhead: 7)
        let initial = (await center.pendingNotificationRequests()).count
        XCTAssertEqual(initial, 7, "baseline: rule active → 7 occurrences scheduled")

        // Simulate undo: scheduler.cancelRule clears pending + flips
        // rule.cancelled_at. This is the exact path UndoExecutor takes for
        // `.cancelRecurringRule(ruleID:)`.
        await scheduler.cancelRule(ruleID: record.ruleID)
        let afterCancel = (await center.pendingNotificationRequests()).count
        XCTAssertEqual(afterCancel, 0, "cancelRule must remove every pending occurrence")

        // Next foreground tick must NOT reissue — rule is cancelled. If the
        // rule lookup didn't filter by cancelled_at, this would re-schedule
        // all 7 days and the test would fail.
        await scheduler.topUpHorizon(daysAhead: 7)
        let afterTopUp = (await center.pendingNotificationRequests()).count
        XCTAssertEqual(afterTopUp, 0, "topUpHorizon must NOT re-issue a cancelled rule")
    }

    private func defaultTestSettings() -> Settings {
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

    func testTopUpHorizonSkipsAlreadyScheduledOccurrences() async throws {
        // Running topUpHorizon twice in a row must NOT double-schedule the
        // same occurrence. Idempotency is critical because foreground tick
        // fires this on every launch.
        let (store, _, dir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = RecurringRuleRecord(
            rrule: "FREQ=DAILY;BYHOUR=7;BYMINUTE=0",
            kind: .morningBrief,
            templateContextJSON: "{}",
            priority: 100
        )
        _ = try await store.insert(record)

        let center = FakeUNCenter()
        let tz = TimeZone(identifier: "America/New_York")!
        var noonComps = DateComponents()
        noonComps.year = 2026; noonComps.month = 5; noonComps.day = 17
        noonComps.hour = 12; noonComps.minute = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let clock = FixedClock(cal.date(from: noonComps)!)

        let scheduler = NotificationScheduler(
            center: center,
            settings: FakeSettingsProvider(snapshot: defaultTestSettings()),
            clock: clock,
            timeZone: { tz },
            ruleStore: { store }
        )

        await scheduler.topUpHorizon(daysAhead: 7)
        let firstPass = (await center.pendingNotificationRequests()).count
        await scheduler.topUpHorizon(daysAhead: 7)
        let secondPass = (await center.pendingNotificationRequests()).count
        XCTAssertEqual(firstPass, secondPass, "second topUpHorizon must be a no-op")
    }
}
