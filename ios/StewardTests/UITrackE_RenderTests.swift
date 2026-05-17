//
//  UITrackE_RenderTests.swift
//  StewardTests — Track E
//
//  Pure-Swift tests for Track E's UI primitives. No UIKit / XCUI — we test
//  the deterministic helpers + the instrument projector + the tool-call
//  verb/object table. These run on the unit-test target and give us the
//  "a few UI tests" coverage required by the DoD without standing up an
//  XCUITest harness.
//

import XCTest
@testable import Steward

final class UITrackE_RenderTests: XCTestCase {

    // MARK: - DomainColor

    func testDomainColorIsStablePerDomain() {
        let a1 = DomainColor.for(domain: "health")
        let a2 = DomainColor.for(domain: "health")
        XCTAssertEqual(a1, a2, "Same domain must map to same color across calls.")
    }

    func testDomainColorDistributesAcrossPalette() {
        // Different domains should not all collide on one color. We don't
        // require uniqueness over an arbitrary set, just that the palette
        // is being used.
        var seen: Set<String> = []
        for s in ["health", "money", "home", "social", "hobbies", "therapy"] {
            seen.insert(DomainColor.fnv1aHash(s).description)
        }
        XCTAssertGreaterThan(seen.count, 3, "Domain hashes should be diverse.")
    }

    // MARK: - InstrumentDisplayProjector

    func testRunningAccumulatorRendersPrimaryAndDelta() {
        let stateJSON = """
        {"today_total": 10.0, "yesterday_total": 8.0}
        """
        let defJSON = """
        {"unit": "miles"}
        """
        let display = InstrumentDisplayProjector.project(
            kindID: "running_accumulator",
            stateJSON: stateJSON,
            definitionJSON: defJSON,
            lastUpdatedAt: Date(),
            now: Date()
        )
        XCTAssertEqual(display.primary, "10")
        XCTAssertEqual(display.unit, "miles")
        XCTAssertEqual(display.delta.symbol, "arrow.up.right",
                       "10 vs 8 → improvement.")
    }

    func testBoundedBudgetRendersUsedOverLimit() {
        let stateJSON = """
        {"used": 172, "limit": 300, "days_left_in_window": 4}
        """
        let display = InstrumentDisplayProjector.project(
            kindID: "bounded_budget",
            stateJSON: stateJSON,
            definitionJSON: "{\"unit\":\"$\"}",
            lastUpdatedAt: Date(),
            now: Date()
        )
        XCTAssertEqual(display.primary, "$172 / $300")
        XCTAssertEqual(display.delta.text, "4 days left in window")
    }

    func testUnreadableInstrumentFallsBackToDash() {
        let display = InstrumentDisplayProjector.project(
            kindID: "running_accumulator",
            stateJSON: "{ not valid json",
            definitionJSON: "{}",
            lastUpdatedAt: Date(),
            now: Date()
        )
        XCTAssertEqual(display.primary, "—")
    }

    func testStaleLabelAppearsAfter48h() {
        let stateJSON = "{\"today_total\": 3}"
        let defJSON = "{}"
        let now = Date()
        let old = now.addingTimeInterval(-3 * 24 * 3600)
        let display = InstrumentDisplayProjector.project(
            kindID: "running_accumulator",
            stateJSON: stateJSON,
            definitionJSON: defJSON,
            lastUpdatedAt: old,
            now: now
        )
        XCTAssertTrue(
            display.staleLabel?.hasPrefix("last logged") == true,
            "Expected stale label, got \(display.staleLabel ?? "nil")"
        )
    }

    // MARK: - ToolCallSummaryBuilder

    func testInstrumentApplyEventCardLabelsCorrectly() {
        let inv = LLMToolInvocation(
            toolID: ToolID.instrumentApplyEvent.rawValue,
            argsJSON: """
            {"instrument_id":"weight_trend","reasoning":"User said 178.","payload":{"value":178}}
            """,
            resultJSON: "{\"event_id\":\"abc\"}",
            executedAt: Date()
        )
        let summary = ToolCallSummaryBuilder.build(
            invocation: inv,
            defaultActorLabel: "Steward",
            defaultDomainKey: nil,
            eventID: "abc"
        )
        XCTAssertEqual(summary.verb, "updated")
        XCTAssertEqual(summary.object, "weight_trend")
        XCTAssertTrue(summary.isReversible)
        XCTAssertEqual(summary.reasoning, "User said 178.")
    }

    func testCalendarReadIsNotReversible() {
        let inv = LLMToolInvocation(
            toolID: ToolID.calendarRead.rawValue,
            argsJSON: "{\"start\":\"2026-05-17T00:00:00Z\",\"end\":\"2026-05-18T00:00:00Z\"}",
            resultJSON: "[]",
            executedAt: Date()
        )
        let summary = ToolCallSummaryBuilder.build(
            invocation: inv,
            defaultActorLabel: "Steward",
            defaultDomainKey: nil,
            eventID: nil
        )
        XCTAssertFalse(summary.isReversible)
    }

    func testDomainAgentToolCallLabelsTeam() {
        let inv = LLMToolInvocation(
            toolID: ToolID.instrumentApplyEvent.rawValue,
            argsJSON: """
            {"instrument_id":"sleep","domain":"health","reasoning":"User said 7."}
            """,
            resultJSON: "{}",
            executedAt: Date()
        )
        let summary = ToolCallSummaryBuilder.build(
            invocation: inv,
            defaultActorLabel: "Steward",
            defaultDomainKey: nil,
            eventID: nil
        )
        XCTAssertEqual(summary.actorLabel, "Health team")
        XCTAssertEqual(summary.domainKey, "health")
    }

    // MARK: - CoordinatorEmptyStateCopy is what Chat renders

    func testGreetingMatchesUXRForMorningHour() {
        let copy = CoordinatorEmptyStateCopy.greeting(forLocalHour: 7)
        XCTAssertTrue(copy.hasPrefix("Morning. I'm Steward."),
                      "Greeting at 7am must begin with 'Morning. I'm Steward.'; got: \(copy)")
        XCTAssertFalse(copy.lowercased().contains("decay"))
        XCTAssertFalse(copy.lowercased().contains("hardest to keep up"))
    }
}
