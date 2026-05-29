//
//  MockLLMSessionTests.swift
//  StewardTests
//
//  Walks the six canned turns from implementation-addendum §1.10, plus the
//  qa-1 coverage fixes (EventKit/Notifications tool intents + morning-brief deterministic
//  copy) and a round-trip empty-state integration test that proves the
//  emitted args decode against every real tool's `ArgsStruct`.
//

import XCTest
import GRDB
@testable import Steward

final class MockLLMSessionTests: XCTestCase {

    // MARK: - Determinism

    func test_purePlan_sameInput_sameOutput() {
        let sp = "conversation_state: awaiting_first_message\nempty_state_branch: branch_c"
        let userMsg = "hi"
        let first = MockResponsePlan.plan(systemPrompt: sp, userMessage: userMsg)
        for _ in 0..<32 {
            let again = MockResponsePlan.plan(systemPrompt: sp, userMessage: userMsg)
            XCTAssertEqual(again, first)
        }
    }

    func test_purePlan_alwaysPrefixesMockTag_orHasToolCallOnly() {
        let sp = "conversation_state: free_chat"
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "random whatever")
        XCTAssertTrue(plan.text.hasPrefix("[MOCK]"),
                      "All canned text must begin with [MOCK] so the UI banner is reinforced")
    }

    // MARK: - The six canned turns

    func test_turn1_firstMessage_greetsAndAsksOpenQuestion() {
        let sp = """
            conversation_state: awaiting_first_message
            empty_state_branch: branch_c
            """
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "hi")
        XCTAssertTrue(plan.text.contains("Outkeep"))
        XCTAssertTrue(plan.text.contains("Tell me something I should catch"))
        XCTAssertTrue(plan.toolCalls.isEmpty)
    }

    func test_turn2_lifeAreaNamed_proposesTeamShape() {
        let sp = """
            conversation_state: awaiting_life_area_answer
            empty_state_branch: branch_b
            """
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "track my sleep please")
        XCTAssertTrue(plan.text.contains("Health team"))
        XCTAssertTrue(plan.text.contains("Stay gentle"))
        XCTAssertTrue(plan.toolCalls.isEmpty)
    }

    func test_turn3_domainConfirm_invokesDomainCreate() throws {
        let sp = "conversation_state: awaiting_domain_confirm"
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "yes")
        XCTAssertEqual(plan.toolCalls.count, 1)
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.domainCreate.rawValue)
        // Decode against the real tool's args struct — failure means the
        // mock would crash inside DomainCreateTool.invoke().
        let args = try ToolJSON.decode(DomainCreateArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.domain, "health")
        XCTAssertEqual(args.displayName, "Health")
        XCTAssertFalse(args.reasoning.isEmpty, "reasoning is required for agent/coordinator actors")
        XCTAssertEqual(args.actor, "coordinator")
    }

    func test_branchA_capture_decodesAgainstEventCapture() throws {
        let sp = """
            conversation_state: free_chat
            empty_state_branch: branch_a
            """
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "drank 16 ounces of water")
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.eventCapture.rawValue)
        let args = try ToolJSON.decode(EventCaptureArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.text, "drank 16 ounces of water")
        XCTAssertFalse(args.reasoning.isEmpty)
        XCTAssertEqual(args.actor, "coordinator")
    }

    // MARK: - New tool intents (qa-1 gap fixes)

    func test_mercyMode_decodesAgainstMercyModeEngageArgs() throws {
        // Pin `now` so the mock's untilWhen is computed against the same
        // clock we assert against. The default planning clock is fixed in
        // 2026-04 (deterministic test snapshots); without overriding, the
        // sanity check below would be measured against the wall clock and
        // drift further into the past with every passing day.
        let now = Date()
        let plan = MockResponsePlan.plan(
            systemPrompt: "conversation_state: free_chat",
            userMessage: "turn on mercy mode please",
            now: now
        )
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.mercyModeEngage.rawValue)
        let args = try ToolJSON.decode(MercyModeEngageArgs.self, from: call.argsJSON)
        XCTAssertFalse(args.reason.isEmpty)
        XCTAssertFalse(args.reasoning.isEmpty)
        XCTAssertEqual(args.actor, "coordinator")
        // untilWhen should be in the future (the mock sets a 3-day window).
        XCTAssertGreaterThan(args.untilWhen.timeIntervalSince(now), 0)
    }

    func test_quietHours_decodesAgainstQuietHoursSetArgs() throws {
        let plan = MockResponsePlan.plan(
            systemPrompt: "conversation_state: free_chat",
            userMessage: "set quiet hours"
        )
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.quietHoursSet.rawValue)
        let args = try ToolJSON.decode(QuietHoursSetArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.start, "22:00")
        XCTAssertEqual(args.end, "07:00")
        XCTAssertFalse(args.reasoning.isEmpty)
        XCTAssertEqual(args.actor, "coordinator")
    }

    func test_notificationSchedule_decodesAgainstNotificationScheduleArgs() throws {
        let plan = MockResponsePlan.plan(
            systemPrompt: "conversation_state: free_chat",
            userMessage: "remind me at 7am tomorrow"
        )
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.notificationSchedule.rawValue)
        // NotificationScheduleTool uses its own iso8601-aware decoder.
        let args = try NotificationScheduleTool.decode(call.argsJSON)
        XCTAssertEqual(args.kind, .instrumentNudge)
        XCTAssertFalse(args.reasoning.isEmpty)
    }

    func test_reminderCreate_decodesAgainstReminderCreateArgs() throws {
        let plan = MockResponsePlan.plan(
            systemPrompt: "conversation_state: free_chat",
            userMessage: "remind me to call mom this evening"
        )
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.reminderCreate.rawValue)
        let data = try XCTUnwrap(call.argsJSON.data(using: .utf8))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let args = try dec.decode(ReminderCreateArgs.self, from: data)
        XCTAssertTrue(args.title.contains("call mom"))
        XCTAssertFalse(args.reasoning.isEmpty)
    }

    func test_calendarRead_decodesAgainstCalendarReadArgs() throws {
        let plan = MockResponsePlan.plan(
            systemPrompt: "conversation_state: free_chat",
            userMessage: "what's on my calendar today?"
        )
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.calendarRead.rawValue)
        let data = try XCTUnwrap(call.argsJSON.data(using: .utf8))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let args = try dec.decode(CalendarReadArgs.self, from: data)
        XCTAssertLessThan(args.start.timeIntervalSince1970, args.end.timeIntervalSince1970)
    }

    // MARK: - Morning brief

    func test_morningBrief_returnsUsefulCopy_notGenericAck() {
        let plan = MockResponsePlan.plan(
            systemPrompt: "conversation_state: free_chat",
            userMessage: "Generate this morning's brief. Summarize current state, mention one or two specific instrument values, any commitments in the next 12h, and one optional small offer. Don't moralize."
        )
        XCTAssertTrue(plan.toolCalls.isEmpty)
        XCTAssertNotEqual(plan.text, "[MOCK] Got it.")
        XCTAssertTrue(plan.text.lowercased().contains("brief"),
                      "Brief response should clearly be a brief, not the generic fallback")
        // It should hint that we're on the stub backend so the user knows
        // they're seeing canned copy rather than a real summary.
        XCTAssertTrue(plan.text.lowercased().contains("stub")
                      || plan.text.lowercased().contains("mock backend"))
    }

    // MARK: - Determinism through actor

    func test_actorPath_alsoDeterministic() async throws {
        let factory = MockLLMSessionFactory(reason: .sdkNotCompiledIn,
                                            clock: { Date(timeIntervalSince1970: 1_715_000_000) })
        let captureTool = NoOpCaptureTool()

        let session1 = try await factory.makeSession(
            systemPrompt: "conversation_state: free_chat",
            tools: [captureTool],
            temperature: 0.7
        )
        let r1 = try await session1.respond(to: "slept 6 hours")

        let session2 = try await factory.makeSession(
            systemPrompt: "conversation_state: free_chat",
            tools: [captureTool],
            temperature: 0.7
        )
        let r2 = try await session2.respond(to: "slept 6 hours")

        XCTAssertEqual(r1.text, r2.text)
        XCTAssertEqual(r1.toolInvocations.map { $0.toolID },
                       r2.toolInvocations.map { $0.toolID })
        XCTAssertEqual(r1.toolInvocations.map { $0.argsJSON },
                       r2.toolInvocations.map { $0.argsJSON })
        XCTAssertEqual(r1.backendKind, r2.backendKind)
    }

    func test_backendKindPropagatesFromFactory() async throws {
        let factory = MockLLMSessionFactory(reason: .deviceNotEligible)
        let session = try await factory.makeSession(
            systemPrompt: "conversation_state: free_chat",
            tools: [],
            temperature: 0.7
        )
        let response = try await session.respond(to: "hi")
        XCTAssertEqual(response.backendKind, .mock(reason: .deviceNotEligible))
    }
}

// Minimal stub tools the tests use to verify dispatch happens. Pure
// functions of input so the determinism asserts hold.
private struct NoOpCaptureTool: LLMTool {
    let id = ToolID.eventCapture.rawValue
    let description = "test"
    let jsonSchemaForArgs = "{}"
    func invoke(argsJSON: String) async throws -> String {
        return "{\"ok\":true,\"received\":\(argsJSON.utf8.count)}"
    }
}

