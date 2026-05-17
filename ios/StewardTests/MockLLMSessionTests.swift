//
//  MockLLMSessionTests.swift
//  StewardTests — Track B
//
//  Walks the six canned turns from implementation-addendum §1.10.
//

import XCTest
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

    func test_turn3_domainConfirm_invokesDomainCreate() {
        let sp = "conversation_state: awaiting_domain_confirm"
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "yes")
        XCTAssertEqual(plan.toolCalls.count, 1)
        XCTAssertEqual(plan.toolCalls.first?.toolID, ToolID.domainCreate.rawValue)
        XCTAssertTrue(plan.toolCalls.first?.argsJSON.contains("\"domain\":\"health\"") ?? false)
    }

    func test_turn4_instrumentConfirm_invokesInstrumentCreate() {
        let sp = "conversation_state: awaiting_instrument_confirm"
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "yes please")
        XCTAssertEqual(plan.toolCalls.count, 1)
        XCTAssertEqual(plan.toolCalls.first?.toolID, ToolID.instrumentCreate.rawValue)
        XCTAssertTrue(plan.toolCalls.first?.argsJSON.contains("rolling_average") ?? false)
    }

    func test_turn5_eventLog_invokesApplyEvent() {
        let sp = "conversation_state: free_chat"
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "slept 6 hours")
        XCTAssertEqual(plan.toolCalls.count, 1)
        XCTAssertEqual(plan.toolCalls.first?.toolID, ToolID.instrumentApplyEvent.rawValue)
    }

    func test_turn6_statusRead_invokesInstrumentRead() {
        let sp = "conversation_state: free_chat"
        let plan = MockResponsePlan.plan(systemPrompt: sp, userMessage: "how am i doing on sleep this week?")
        XCTAssertEqual(plan.toolCalls.count, 1)
        XCTAssertEqual(plan.toolCalls.first?.toolID, ToolID.instrumentRead.rawValue)
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
