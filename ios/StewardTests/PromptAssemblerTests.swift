//
//  PromptAssemblerTests.swift
//  StewardTests — Track B
//
//  Asserts §1.7 segment ordering: identity, invariant_open, role_prompt,
//  runtime_context, tool_catalog, invariant_close.
//
//  Hard reject #12: role_prompt MUST come AFTER the first invariant block.
//

import XCTest
@testable import Steward

final class PromptAssemblerTests: XCTestCase {

    private func makeRuntime(role: AgentRole) -> RuntimeContext {
        return RuntimeContext(
            now: Date(timeIntervalSince1970: 1_715_900_000),
            localTimezone: TimeZone(identifier: "America/New_York")!,
            conversationState: .awaitingFirstMessage,
            emptyStateBranch: .branchCUnclear,
            mercyMode: .off,
            pauseUntil: nil,
            activeDomains: [],
            openCommitments: [],
            recentEventsSummary: nil,
            memoryHitsSummary: nil,
            todayCalendarSummary: nil,
            userMessage: "hi",
            priorTurnSummary: nil
        )
    }

    // MARK: - Segment ordering

    func test_segmentOrder_isFixed() {
        let assembler = PromptAssembler()
        let prompt = assembler.assemble(
            for: .coordinator,
            runtime: makeRuntime(role: .coordinator),
            scope: .coordinatorAll
        )
        let labels = prompt.segments.map { $0.label }
        XCTAssertEqual(labels, [
            "identity",
            "invariant_opening",
            "role_prompt",
            "runtime_context",
            "tool_catalog",
            "invariant_closing",
        ])
    }

    // MARK: - Invariant markers present FIRST and LAST

    func test_invariantBlocks_firstAndLast() {
        let assembler = PromptAssembler()
        let prompt = assembler.assemble(
            for: .coordinator,
            runtime: makeRuntime(role: .coordinator),
            scope: .coordinatorAll
        )
        XCTAssertEqual(prompt.invariantIndices.count, 2)
        XCTAssertEqual(prompt.invariantIndices.first, 1) // index 1 = invariant_opening
        XCTAssertEqual(prompt.invariantIndices.last, prompt.segments.count - 1)
    }

    func test_invariantMarkers_renderInText() {
        let assembler = PromptAssembler()
        let prompt = assembler.assemble(
            for: .coordinator,
            runtime: makeRuntime(role: .coordinator),
            scope: .coordinatorAll
        )
        // Two opening markers + two closing markers (one pair per invariant block).
        let openCount = countOccurrences(of: "<<INVARIANT>>", in: prompt.text)
        let closeCount = countOccurrences(of: "<</INVARIANT>>", in: prompt.text)
        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(closeCount, 2)
    }

    // MARK: - role_prompt cannot escape invariants

    func test_rolePrompt_isSandwiched() {
        let assembler = PromptAssembler()
        let prompt = assembler.assemble(
            for: .coordinator,
            runtime: makeRuntime(role: .coordinator),
            scope: .coordinatorAll
        )
        guard
            let rolePromptIdx = prompt.segments.firstIndex(where: { $0.label == "role_prompt" })
        else {
            XCTFail("missing role_prompt segment")
            return
        }
        let firstInvariant = prompt.invariantIndices.first ?? -1
        let lastInvariant = prompt.invariantIndices.last ?? -1
        XCTAssertGreaterThan(rolePromptIdx, firstInvariant,
                             "role_prompt must come AFTER the opening invariant block")
        XCTAssertLessThan(rolePromptIdx, lastInvariant,
                          "role_prompt must come BEFORE the closing invariant block")
    }

    // MARK: - MOCK_HINT token surfaces

    func test_runtimeContext_carriesConversationStateAsMockHint() {
        let assembler = PromptAssembler()
        var runtime = makeRuntime(role: .coordinator)
        runtime.conversationState = .awaitingDomainConfirm
        runtime.emptyStateBranch = .branchBSetupFirst
        let prompt = assembler.assemble(for: .coordinator, runtime: runtime, scope: .coordinatorAll)
        XCTAssertTrue(prompt.text.contains("conversation_state: awaiting_domain_confirm"))
        XCTAssertTrue(prompt.text.contains("empty_state_branch: branch_b"))
    }

    // MARK: - Domain agent role prompt

    func test_domainAgent_promptUsesDomainRole() {
        let assembler = PromptAssembler()
        let runtime = makeRuntime(role: .domain("health"))
        let prompt = assembler.assemble(
            for: .domain("health"),
            runtime: runtime,
            scope: .domain("health")
        )
        XCTAssertTrue(prompt.text.contains("health"))
        // Domain agents do NOT get agent.handoff in scope.
        XCTAssertFalse(prompt.text.contains("- agent.handoff"))
    }

    // MARK: - Banned-token instruction is present

    /// The invariant block tells the model what NOT to say. Earlier we
    /// asserted these phrases never appear in the prompt at all — but
    /// that's the wrong assertion: the prompt MUST list the banned
    /// phrases inside the don't-do-this rule so the LLM can recognize
    /// and avoid them.
    func test_invariantBlock_listsBannedShameTokens() {
        let assembler = PromptAssembler()
        let runtime = makeRuntime(role: .coordinator)
        let text = assembler.assemble(
            for: .coordinator,
            runtime: runtime,
            scope: .coordinatorAll
        ).text
        // These show up inside the NEVER... / banned-tokens... lines.
        XCTAssertTrue(text.contains("you should have"))
        XCTAssertTrue(text.contains("let's get back on track"))
        XCTAssertTrue(text.contains("streak"))
    }

    // MARK: - Helpers

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = r.upperBound..<haystack.endIndex
        }
        return count
    }
}
