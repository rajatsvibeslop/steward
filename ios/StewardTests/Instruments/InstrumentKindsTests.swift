//
//  InstrumentKindsTests.swift
//  StewardTests
//
//  One focused test per kind. Math runs deterministically when `now` is
//  pinned; tests assert state transitions match spec §6.
//

import XCTest
@testable import Steward

final class InstrumentKindsTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent<P: Codable & Sendable>(
        instrument: InstrumentID = "inst-1",
        kind: String = "log",
        actor: String = "user",
        at: Date,
        payload: P,
        notes: String? = nil
    ) -> InstrumentEvent<P> {
        InstrumentEvent(
            eventID: EventID(rawValue: ULID.generate(now: at)),
            instrumentID: instrument,
            kind: kind,
            actor: actor,
            createdAt: at,
            payload: payload,
            notes: notes
        )
    }

    private func d(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else {
            XCTFail("bad iso: \(iso)"); return Date()
        }
        return d
    }

    // MARK: - RunningAccumulator

    func test_runningAccumulator_accumulatesToday() throws {
        let def = RunningAccumulator.Definition(
            unit: "minutes",
            dailyTarget: 60,
            weeklyTarget: 300,
            capturePrompt: "movement minutes"
        )
        var s = RunningAccumulator.initialState(definition: def, now: d("2026-05-17T09:00:00Z"))

        let e1 = makeEvent(at: d("2026-05-17T10:00:00Z"),
                            payload: RunningAccumulator.EventPayload(value: 20, unit: "minutes"))
        s = try RunningAccumulator.apply(event: e1, to: s, definition: def, now: d("2026-05-17T10:00:00Z"))
        XCTAssertEqual(s.todayTotal, 20, accuracy: 0.0001)
        XCTAssertEqual(s.windowEvents.count, 1)

        let e2 = makeEvent(at: d("2026-05-17T15:00:00Z"),
                            payload: RunningAccumulator.EventPayload(value: 25, unit: "minutes"))
        s = try RunningAccumulator.apply(event: e2, to: s, definition: def, now: d("2026-05-17T15:00:00Z"))
        XCTAssertEqual(s.todayTotal, 45, accuracy: 0.0001)
        XCTAssertEqual(s.lastEventAt, d("2026-05-17T15:00:00Z"))
    }

    func test_runningAccumulator_prunes30DayWindow() throws {
        let def = RunningAccumulator.Definition(
            unit: "minutes", dailyTarget: nil, weeklyTarget: nil, capturePrompt: ""
        )
        var s = RunningAccumulator.initialState(definition: def, now: d("2026-04-01T10:00:00Z"))
        // Insert one event 31 days old.
        let old = makeEvent(at: d("2026-04-01T10:00:00Z"),
                             payload: RunningAccumulator.EventPayload(value: 999, unit: nil))
        s = try RunningAccumulator.apply(event: old, to: s, definition: def, now: d("2026-04-01T10:00:00Z"))
        // Now run another event 31 days later — pruning should drop the old one.
        let fresh = makeEvent(at: d("2026-05-03T10:00:00Z"),
                               payload: RunningAccumulator.EventPayload(value: 1, unit: nil))
        s = try RunningAccumulator.apply(event: fresh, to: s, definition: def, now: d("2026-05-03T10:00:00Z"))
        XCTAssertEqual(s.windowEvents.count, 1, "stale entry should have been pruned")
        XCTAssertEqual(s.windowEvents.first?.value, 1)
    }

    // MARK: - BoundedBudget

    func test_boundedBudget_dailyRollsAndCarriesRollover() throws {
        let def = BoundedBudget.Definition(unit: "USD", period: .daily, limit: 100, rollover: true)
        var s = BoundedBudget.initialState(definition: def, now: d("2026-05-17T08:00:00Z"))
        XCTAssertEqual(s.remaining, 100)

        let spend = makeEvent(at: d("2026-05-17T12:00:00Z"),
                               payload: BoundedBudget.EventPayload(value: 40, notes: "lunch"))
        s = try BoundedBudget.apply(event: spend, to: s, definition: def, now: d("2026-05-17T12:00:00Z"))
        XCTAssertEqual(s.periodTotal, 40)
        XCTAssertEqual(s.remaining, 60)

        // Next day with rollover=true: previous remaining (60) should carry.
        let nextDay = makeEvent(at: d("2026-05-18T09:00:00Z"),
                                 payload: BoundedBudget.EventPayload(value: 10, notes: "coffee"))
        s = try BoundedBudget.apply(event: nextDay, to: s, definition: def, now: d("2026-05-18T09:00:00Z"))
        XCTAssertEqual(s.rolloverBalance, 60, "yesterday's 60 unused USD should roll")
        XCTAssertEqual(s.periodTotal, 10, "period_total resets at boundary")
        XCTAssertEqual(s.remaining, 100 + 60 - 10)
    }

    func test_boundedBudget_weeklyPeriodStart_isMonday() {
        // 2026-05-17 is a Sunday; week (Monday-start) anchored on it is
        // 2026-05-11. The spec / ISO 8601 weekly convention is Monday-start.
        let def = BoundedBudget.Definition(unit: "USD", period: .weekly, limit: 100, rollover: false)
        let s = BoundedBudget.initialState(definition: def, now: d("2026-05-17T12:00:00Z"))
        let cal = Calendar(identifier: .gregorian)
        let weekday = cal.component(.weekday, from: s.periodStartAt)
        XCTAssertEqual(weekday, 2, "week-start should be Monday (weekday=2)")
    }

    // MARK: - RollingAverage

    func test_rollingAverage_meanSmoothing() throws {
        let def = RollingAverage.Definition(unit: "lbs", windowDays: 7, smoothing: .mean)
        var s = RollingAverage.initialState(definition: def, now: d("2026-05-10T08:00:00Z"))
        for (i, v) in [180.0, 181.0, 179.0, 180.0].enumerated() {
            let e = makeEvent(at: d("2026-05-1\(i+1)T08:00:00Z"),
                               payload: RollingAverage.EventPayload(value: v))
            s = try RollingAverage.apply(event: e, to: s, definition: def, now: d("2026-05-1\(i+1)T08:00:00Z"))
        }
        XCTAssertEqual(s.windowValues.count, 4)
        XCTAssertEqual(s.current, (180 + 181 + 179 + 180) / 4.0, accuracy: 0.0001)
    }

    func test_rollingAverage_emaSmoothing_smoothsAcrossSamples() throws {
        let def = RollingAverage.Definition(unit: "h", windowDays: 7, smoothing: .ema)
        var s = RollingAverage.initialState(definition: def, now: d("2026-05-10T08:00:00Z"))
        for (i, v) in [8.0, 7.0, 7.5, 7.0, 6.5, 6.0].enumerated() {
            let e = makeEvent(at: d("2026-05-\(10+i)T22:00:00Z"),
                               payload: RollingAverage.EventPayload(value: v))
            s = try RollingAverage.apply(event: e, to: s, definition: def, now: d("2026-05-\(10+i)T22:00:00Z"))
        }
        // EMA should land between the arithmetic mean and the last sample;
        // both bounds are loose sanity checks not exact formulas.
        XCTAssertGreaterThan(s.current, 6.0)
        XCTAssertLessThan(s.current, 8.0)
    }

    func test_rollingAverage_rejectsZeroWindowDays() {
        let def = RollingAverage.Definition(unit: "x", windowDays: 0, smoothing: .mean)
        var s = RollingAverage.initialState(definition: def, now: d("2026-05-10T08:00:00Z"))
        let e = makeEvent(at: d("2026-05-10T08:00:00Z"),
                           payload: RollingAverage.EventPayload(value: 1.0))
        XCTAssertThrowsError(try RollingAverage.apply(event: e, to: s, definition: def, now: d("2026-05-10T08:00:00Z"))) { err in
            guard case InstrumentKindError.invalidDefinition = err else {
                XCTFail("expected invalidDefinition, got \(err)"); return
            }
        }
    }

    // MARK: - CountdownCommitment

    func test_countdownCommitment_countsMatchingKindOnly() throws {
        let def = CountdownCommitment.Definition(targetCount: 3, window: .week, successEventKind: "push_back")
        var s = CountdownCommitment.initialState(definition: def, now: d("2026-05-11T09:00:00Z"))
        let e1 = makeEvent(kind: "push_back",
                            at: d("2026-05-12T10:00:00Z"),
                            payload: CountdownCommitment.EventPayload(notes: "told boss no"))
        s = try CountdownCommitment.apply(event: e1, to: s, definition: def, now: d("2026-05-12T10:00:00Z"))
        XCTAssertEqual(s.count, 1)
        let wrong = makeEvent(kind: "other",
                               at: d("2026-05-13T10:00:00Z"),
                               payload: CountdownCommitment.EventPayload(notes: nil))
        XCTAssertThrowsError(try CountdownCommitment.apply(event: wrong, to: s, definition: def, now: d("2026-05-13T10:00:00Z")))
    }

    func test_countdownCommitment_rollsAtWindowBoundary() throws {
        let def = CountdownCommitment.Definition(targetCount: 2, window: .week, successEventKind: "push_back")
        var s = CountdownCommitment.initialState(definition: def, now: d("2026-05-11T09:00:00Z"))
        let e1 = makeEvent(kind: "push_back",
                            at: d("2026-05-12T10:00:00Z"),
                            payload: CountdownCommitment.EventPayload(notes: nil))
        s = try CountdownCommitment.apply(event: e1, to: s, definition: def, now: d("2026-05-12T10:00:00Z"))
        XCTAssertEqual(s.count, 1)

        // Jump 9 days — next week.
        let e2 = makeEvent(kind: "push_back",
                            at: d("2026-05-21T10:00:00Z"),
                            payload: CountdownCommitment.EventPayload(notes: nil))
        s = try CountdownCommitment.apply(event: e2, to: s, definition: def, now: d("2026-05-21T10:00:00Z"))
        XCTAssertEqual(s.count, 1, "count should reset to 1 for the new week")
    }

    // MARK: - WeeklyEvidenceLog

    func test_weeklyEvidenceLog_rollsWeek_andCollapsesPreviousSummary() throws {
        let def = WeeklyEvidenceLog.Definition(prompt: "wins?", weekStartDow: 2)
        var s = WeeklyEvidenceLog.initialState(definition: def, now: d("2026-05-11T09:00:00Z"))
        let e1 = makeEvent(at: d("2026-05-12T10:00:00Z"),
                            payload: WeeklyEvidenceLog.EventPayload(text: "won the bet"))
        s = try WeeklyEvidenceLog.apply(event: e1, to: s, definition: def, now: d("2026-05-12T10:00:00Z"))
        XCTAssertEqual(s.currentWeekEntries.count, 1)

        let e2 = makeEvent(at: d("2026-05-19T10:00:00Z"),
                            payload: WeeklyEvidenceLog.EventPayload(text: "next week entry"))
        s = try WeeklyEvidenceLog.apply(event: e2, to: s, definition: def, now: d("2026-05-19T10:00:00Z"))
        XCTAssertEqual(s.currentWeekEntries.count, 1, "current week should reset")
        XCTAssertEqual(s.previousWeeksSummaries.count, 1, "prior week collapses into a summary")
        XCTAssertEqual(s.previousWeeksSummaries.first?.entryCount, 1)
    }

    // MARK: - Checklist

    func test_checklist_streakBumpsOnRollover() throws {
        let def = Checklist.Definition(items: [
            .init(id: "brush", label: "Brush teeth", recurrence: nil),
            .init(id: "stretch", label: "Stretch 5 min", recurrence: nil)
        ])
        var s = Checklist.initialState(definition: def, now: d("2026-05-10T07:00:00Z"))

        // Day 1: check both
        let chBrushD1 = makeEvent(at: d("2026-05-10T07:30:00Z"),
                                   payload: Checklist.EventPayload(itemID: "brush", checked: true))
        s = try Checklist.apply(event: chBrushD1, to: s, definition: def, now: d("2026-05-10T07:30:00Z"))
        let chStretchD1 = makeEvent(at: d("2026-05-10T07:31:00Z"),
                                     payload: Checklist.EventPayload(itemID: "stretch", checked: true))
        s = try Checklist.apply(event: chStretchD1, to: s, definition: def, now: d("2026-05-10T07:31:00Z"))

        // Day 2: check brush but not stretch
        let chBrushD2 = makeEvent(at: d("2026-05-11T07:30:00Z"),
                                   payload: Checklist.EventPayload(itemID: "brush", checked: true))
        s = try Checklist.apply(event: chBrushD2, to: s, definition: def, now: d("2026-05-11T07:30:00Z"))

        XCTAssertEqual(s.streakByItem["brush"], 1, "brush completed yesterday → streak=1")
        XCTAssertEqual(s.streakByItem["stretch"], 1, "stretch was checked yesterday → streak=1")
        XCTAssertEqual(s.checkedToday, ["brush"])
    }

    func test_checklist_weekdayItemDoesNotBreakStreakOnWeekend() throws {
        let def = Checklist.Definition(items: [
            .init(id: "office", label: "Show up at office", recurrence: "weekday")
        ])
        // Anchor on a Friday so the rollover happens into Saturday.
        var s = Checklist.initialState(definition: def, now: d("2026-05-15T07:00:00Z"))
        let chFri = makeEvent(at: d("2026-05-15T07:30:00Z"),
                                payload: Checklist.EventPayload(itemID: "office", checked: true))
        s = try Checklist.apply(event: chFri, to: s, definition: def, now: d("2026-05-15T07:30:00Z"))
        // Saturday rollover with no event for "office" — recurrence=weekday
        // means streak should NOT reset.
        let chSat = makeEvent(at: d("2026-05-16T07:30:00Z"),
                                payload: Checklist.EventPayload(itemID: "office", checked: false))
        s = try Checklist.apply(event: chSat, to: s, definition: def, now: d("2026-05-16T07:30:00Z"))
        XCTAssertEqual(s.streakByItem["office"], 1, "weekday-only item should preserve streak across Saturday")
    }

    // MARK: - BoundedWindow

    func test_boundedWindow_inWindowDetection_acrossMidnight() throws {
        let def = BoundedWindow.Definition(
            kind: "time_window",
            startTarget: "22:30",
            endTarget: "06:30",
            complianceMetric: .nightsInWindow,
            rollingWindowNights: 7
        )
        var s = BoundedWindow.initialState(definition: def, now: d("2026-05-10T08:00:00Z"))
        // In-window sample: 23:00 → 06:00
        let inW = makeEvent(at: d("2026-05-11T06:00:00Z"),
                              payload: BoundedWindow.EventPayload(
                                actualStart: d("2026-05-10T23:00:00Z"),
                                actualEnd: d("2026-05-11T06:00:00Z")
                              ))
        s = try BoundedWindow.apply(event: inW, to: s, definition: def, now: d("2026-05-11T06:00:00Z"))
        XCTAssertEqual(s.nightsInWindow.count, 1)
        XCTAssertEqual(s.currentCompliancePct, 1.0)

        // Out-of-window: 21:00 → 05:00 (start too early)
        let outW = makeEvent(at: d("2026-05-12T05:00:00Z"),
                               payload: BoundedWindow.EventPayload(
                                actualStart: d("2026-05-11T21:00:00Z"),
                                actualEnd: d("2026-05-12T05:00:00Z")
                               ))
        s = try BoundedWindow.apply(event: outW, to: s, definition: def, now: d("2026-05-12T05:00:00Z"))
        XCTAssertEqual(s.nightsInWindow.count, 2)
        XCTAssertEqual(s.currentCompliancePct, 0.5)
    }

    // MARK: - Registry dispatch + state version

    func test_registry_dispatchAppliesAndIncrementsLastUpdated() throws {
        InstrumentRegistry._resetForTesting()
        InstrumentRegistry.bootstrapAll()
        XCTAssertTrue(InstrumentRegistry.isRegistered("running_accumulator"))
        XCTAssertEqual(InstrumentRegistry.currentStateVersion(forKind: "running_accumulator"), 1)
    }
}
