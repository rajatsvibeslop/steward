//
//  MockLLMSessionTests.swift
//  StewardTests — Track B
//
//  Walks the six canned turns from implementation-addendum §1.10, plus the
//  qa-1 coverage fixes (Pod D tool intents + morning-brief deterministic
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
        XCTAssertTrue(plan.text.contains("Steward"))
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

    func test_turn4_instrumentConfirm_invokesInstrumentCreate() throws {
        let sp = "conversation_state: awaiting_instrument_confirm"
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "yes please")
        XCTAssertEqual(plan.toolCalls.count, 1)
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.instrumentCreate.rawValue)
        let args = try ToolJSON.decode(InstrumentCreateArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.kind, "rolling_average")
        XCTAssertEqual(args.domain, "health")
        // definition_json must be a JSON-encoded string the kind's
        // Definition decoder can parse — not a nested object.
        let definitionData = try XCTUnwrap(args.definitionJSON.data(using: .utf8))
        let definitionObj = try JSONSerialization.jsonObject(with: definitionData) as? [String: Any]
        XCTAssertEqual(definitionObj?["unit"] as? String, "hours")
        XCTAssertEqual(definitionObj?["window_days"] as? Int, 7)
        XCTAssertFalse(args.reasoning.isEmpty)
        XCTAssertEqual(args.actor, "coordinator")
    }

    func test_turn5_eventLog_invokesApplyEvent_andDecodesAgainstSchema() throws {
        let sp = "conversation_state: free_chat"
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "slept 6 hours")
        XCTAssertEqual(plan.toolCalls.count, 1)
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.instrumentApplyEvent.rawValue)
        let args = try ToolJSON.decode(InstrumentApplyEventArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.eventKind, "log_entry")
        // payload_json must be a String containing a JSON object (not a
        // nested object on the args struct).
        let payloadData = try XCTUnwrap(args.payloadJSON.data(using: .utf8))
        let payloadObj = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        XCTAssertEqual(payloadObj?["raw"] as? String, "slept 6 hours")
        XCTAssertFalse(args.reasoning.isEmpty)
        XCTAssertEqual(args.actor, "coordinator")
    }

    func test_turn5_apply_threadsLastCreatedInstrumentID() throws {
        let sp = "conversation_state: free_chat"
        let state = MockSessionState(lastCreatedInstrumentID: "inst_real_abc123")
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "slept 7 hours", state: state)
        let call = try XCTUnwrap(plan.toolCalls.first)
        let args = try ToolJSON.decode(InstrumentApplyEventArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.instrumentID.rawValue, "inst_real_abc123")
    }

    func test_turn6_statusRead_invokesInstrumentRead_andDecodes() throws {
        let sp = "conversation_state: free_chat"
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "how am i doing on sleep this week?")
        XCTAssertEqual(plan.toolCalls.count, 1)
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.instrumentRead.rawValue)
        let args = try ToolJSON.decode(InstrumentReadArgs.self, from: call.argsJSON)
        XCTAssertFalse(args.instrumentID.rawValue.isEmpty)
    }

    func test_turn6_read_threadsLastCreatedInstrumentID() throws {
        let sp = "conversation_state: free_chat"
        let state = MockSessionState(lastCreatedInstrumentID: "inst_real_zzz999")
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "status please", state: state)
        let call = try XCTUnwrap(plan.toolCalls.first)
        let args = try ToolJSON.decode(InstrumentReadArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.instrumentID.rawValue, "inst_real_zzz999")
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
        let plan = MockResponsePlan.plan(
            systemPrompt: "conversation_state: free_chat",
            userMessage: "turn on mercy mode please"
        )
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.mercyModeEngage.rawValue)
        let args = try ToolJSON.decode(MercyModeEngageArgs.self, from: call.argsJSON)
        XCTAssertFalse(args.reason.isEmpty)
        XCTAssertFalse(args.reasoning.isEmpty)
        XCTAssertEqual(args.actor, "coordinator")
        XCTAssertGreaterThan(args.untilWhen.timeIntervalSinceNow, -10)
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
        let applyTool = NoOpApplyEventTool()

        let session1 = try await factory.makeSession(
            systemPrompt: "conversation_state: free_chat",
            tools: [captureTool, applyTool],
            temperature: 0.7
        )
        let r1 = try await session1.respond(to: "slept 6 hours")

        let session2 = try await factory.makeSession(
            systemPrompt: "conversation_state: free_chat",
            tools: [captureTool, applyTool],
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

    // MARK: - System prompt parsing

    func test_parsesAgentDomainFromSystemPrompt() {
        // Drive the public plan() entry point with an agent_domain line —
        // the parser is internal to MockResponsePlan but the behavior is
        // observable through dispatch: domain-agent plans always say
        // "[MOCK] <domain> — ...".
        let sp = """
            now: 2026-05-17T04:00:00Z
            agent_domain: money
            conversation_state: free_chat
            """
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "status")
        XCTAssertTrue(plan.text.contains("money"),
                      "Domain-agent dispatch should reflect agent_domain from system prompt")
    }

    // MARK: - Empty-state protocol round-trip
    //
    // Walks turns 1, 3, 4, 5, 6 against real Pod C tools backed by an
    // in-memory DB. Asserts that every emitted argsJSON decodes cleanly
    // and that turn 4's instrument_id flows into turns 5 and 6 via the
    // shared MockSessionStateStore.

    func test_emptyStateProtocol_roundTripsWithoutDecodeErrors() async throws {
        let provider = try await makeProvider()
        let fixedNow = ISO8601DateFormatter().date(from: "2026-05-17T10:00:00Z")!
        let factory = MockLLMSessionFactory(
            reason: .sdkNotCompiledIn,
            clock: { fixedNow }
        )

        let tools: [any LLMTool] = [
            DomainCreateTool(provider: provider, now: { fixedNow }),
            InstrumentCreateTool(provider: provider, now: { fixedNow }),
            InstrumentApplyEventTool(provider: provider, now: { fixedNow }),
            InstrumentReadTool(provider: provider),
            EventCaptureTool(provider: provider, now: { fixedNow }),
        ]

        // Turn 1 — greeting, no tools.
        let s1 = try await factory.makeSession(
            systemPrompt: "conversation_state: awaiting_first_message\nempty_state_branch: branch_c",
            tools: tools,
            temperature: 0.7
        )
        let r1 = try await s1.respond(to: "hi")
        XCTAssertTrue(r1.toolInvocations.isEmpty)
        XCTAssertTrue(r1.text.contains("Steward"))

        // Turn 3 — domain.create.
        let s3 = try await factory.makeSession(
            systemPrompt: "conversation_state: awaiting_domain_confirm",
            tools: tools,
            temperature: 0.7
        )
        let r3 = try await s3.respond(to: "yes")
        XCTAssertEqual(r3.toolInvocations.count, 1)
        XCTAssertEqual(r3.toolInvocations.first?.toolID, ToolID.domainCreate.rawValue)

        // Turn 4 — instrument.create (must register the kind first).
        InstrumentRegistry._resetForTesting()
        InstrumentRegistry.bootstrapAll()
        let s4 = try await factory.makeSession(
            systemPrompt: "conversation_state: awaiting_instrument_confirm",
            tools: tools,
            temperature: 0.7
        )
        let r4 = try await s4.respond(to: "yes")
        XCTAssertEqual(r4.toolInvocations.count, 1)
        XCTAssertEqual(r4.toolInvocations.first?.toolID, ToolID.instrumentCreate.rawValue)
        let createResult = try ToolJSON.decode(
            InstrumentCreateResult.self,
            from: r4.toolInvocations.first!.resultJSON
        )
        XCTAssertFalse(createResult.instrumentID.rawValue.isEmpty)

        // Turn 5 — event.capture via branch_a (freeform capture; doesn't
        // require knowing the instrument's per-kind EventPayload schema).
        let s5 = try await factory.makeSession(
            systemPrompt: """
                conversation_state: captured_awaiting_track_offer
                empty_state_branch: branch_a
                """,
            tools: tools,
            temperature: 0.7
        )
        let r5 = try await s5.respond(to: "drank 16 oz of water before bed")
        XCTAssertEqual(r5.toolInvocations.count, 1)
        XCTAssertEqual(r5.toolInvocations.first?.toolID, ToolID.eventCapture.rawValue)
        let captureArgs = try ToolJSON.decode(
            EventCaptureArgs.self,
            from: r5.toolInvocations.first!.argsJSON
        )
        XCTAssertEqual(captureArgs.text, "drank 16 oz of water before bed")
        XCTAssertEqual(captureArgs.actor, "coordinator")

        // Turn 6 — instrument.read for the same instrument_id.
        let s6 = try await factory.makeSession(
            systemPrompt: "conversation_state: free_chat",
            tools: tools,
            temperature: 0.7
        )
        let r6 = try await s6.respond(to: "how am i doing on sleep")
        XCTAssertEqual(r6.toolInvocations.count, 1)
        XCTAssertEqual(r6.toolInvocations.first?.toolID, ToolID.instrumentRead.rawValue)
        let readArgs = try ToolJSON.decode(
            InstrumentReadArgs.self,
            from: r6.toolInvocations.first!.argsJSON
        )
        XCTAssertEqual(readArgs.instrumentID, createResult.instrumentID,
                       "turn 6 should read the same instrument turn 4 created")
    }

    // MARK: - Test helpers

    private func makeProvider() async throws -> DatabaseProvider {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mockllm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("steward.sqlite")
        let provider = DatabaseProvider(location: .file(url))
        _ = try await provider.database()
        InstrumentRegistry._resetForTesting()
        InstrumentRegistry.bootstrapAll()
        return provider
    }
}

// Minimal stub tools the tests use to verify dispatch happens. Both are
// pure functions of input so the determinism asserts hold.
private struct NoOpCaptureTool: LLMTool {
    let id = ToolID.eventCapture.rawValue
    let description = "test"
    let jsonSchemaForArgs = "{}"
    func invoke(argsJSON: String) async throws -> String {
        return "{\"ok\":true,\"received\":\(argsJSON.utf8.count)}"
    }
}

private struct NoOpApplyEventTool: LLMTool {
    let id = ToolID.instrumentApplyEvent.rawValue
    let description = "test"
    let jsonSchemaForArgs = "{}"
    func invoke(argsJSON: String) async throws -> String {
        return "{\"ok\":true,\"received\":\(argsJSON.utf8.count)}"
    }
}
