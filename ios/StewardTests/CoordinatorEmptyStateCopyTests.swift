//
//  CoordinatorEmptyStateCopyTests.swift
//  StewardTests — Track B (deslop B3)
//
//  Verifies that the verbatim UXR v2 §1.1–§5.1 copy templates are
//  injected into the runtime_context block when the coordinator is in
//  empty state, and that the assembled prompt carries them.
//

import XCTest
@testable import Steward

final class CoordinatorEmptyStateCopyTests: XCTestCase {

    // MARK: - Greeting variants (§1.1)

    func test_greeting_morningHour() {
        let g = CoordinatorEmptyStateCopy.greeting(forLocalHour: 7)
        XCTAssertTrue(g.hasPrefix("Morning. I'm Steward."))
        XCTAssertTrue(g.contains("Tell me something I should catch"))
        XCTAssertTrue(g.contains("walk me through it"))
    }

    func test_greeting_afternoon() {
        XCTAssertTrue(CoordinatorEmptyStateCopy.greeting(forLocalHour: 14).hasPrefix("Afternoon."))
    }

    func test_greeting_evening() {
        XCTAssertTrue(CoordinatorEmptyStateCopy.greeting(forLocalHour: 20).hasPrefix("Evening."))
    }

    func test_greeting_smallHours_dropsSalutation() {
        // §1.1 — between 00:00 and 04:00 lead with "I'm Steward."
        let g = CoordinatorEmptyStateCopy.greeting(forLocalHour: 2)
        XCTAssertTrue(g.hasPrefix("I'm Steward."))
        XCTAssertFalse(g.contains("Morning."))
        XCTAssertFalse(g.contains("Evening."))
    }

    // MARK: - Verbatim copy is exact

    func test_branchA_offerSleep_isVerbatim() {
        XCTAssertEqual(
            CoordinatorEmptyStateCopy.branchA_offerSleep,
            "Want me to start keeping sleep for you, so you don't have to remember to log it? Quick yes or no."
        )
    }

    func test_branchB_step6_cadence_isVerbatim() {
        XCTAssertEqual(
            CoordinatorEmptyStateCopy.branchB_step6_cadenceProposal,
            "I'll send a quiet morning brief at 7am tomorrow and a wind-down nudge tonight at 10:30. Sound right?"
        )
    }

    func test_branchC_onRamp_isVerbatim() {
        XCTAssertTrue(CoordinatorEmptyStateCopy.branchC_step1_onRamp.contains("No worries."))
        XCTAssertTrue(CoordinatorEmptyStateCopy.branchC_step1_onRamp.contains("tell me one thing about today"))
        XCTAssertTrue(CoordinatorEmptyStateCopy.branchC_step1_onRamp.contains("no commitment to anything"))
    }

    // MARK: - Banned tokens absent

    func test_copy_neverUsesBannedV2Tokens() {
        let allCopyKeys: [String] = [
            CoordinatorEmptyStateCopy.greeting(forLocalHour: 7),
            CoordinatorEmptyStateCopy.branchA_offerSleep,
            CoordinatorEmptyStateCopy.branchA_offerWeight,
            CoordinatorEmptyStateCopy.branchA_offerMoney,
            CoordinatorEmptyStateCopy.branchA_offerChore,
            CoordinatorEmptyStateCopy.branchA_offerMood,
            CoordinatorEmptyStateCopy.branchA_offerGeneric,
            CoordinatorEmptyStateCopy.branchA_acknowledgementAfterNo,
            CoordinatorEmptyStateCopy.branchA_doneAfterYes,
            CoordinatorEmptyStateCopy.branchB_step1_openQuestion,
            CoordinatorEmptyStateCopy.branchB_step1_chipLabels,
            CoordinatorEmptyStateCopy.branchB_step2_toneToggle,
            CoordinatorEmptyStateCopy.branchB_step3_proposalHealth,
            CoordinatorEmptyStateCopy.branchB_step3_proposalMoney,
            CoordinatorEmptyStateCopy.branchB_step3_proposalHome,
            CoordinatorEmptyStateCopy.branchB_step3_proposalHobbies,
            CoordinatorEmptyStateCopy.branchB_step3_proposalSocial,
            CoordinatorEmptyStateCopy.branchB_step4_afterYes,
            CoordinatorEmptyStateCopy.branchB_step4_afterDifferent,
            CoordinatorEmptyStateCopy.branchB_step4_afterSkip,
            CoordinatorEmptyStateCopy.branchB_step5_secondInstrumentPrompt,
            CoordinatorEmptyStateCopy.branchB_step6_cadenceProposal,
            CoordinatorEmptyStateCopy.branchB_step6_skipNudgesAck,
            CoordinatorEmptyStateCopy.branchB_step7_exit,
            CoordinatorEmptyStateCopy.branchC_step1_onRamp,
            CoordinatorEmptyStateCopy.branchC_step1_vagueExit,
        ]
        let banned = [
            "what's been hardest to keep up with",
            "what you've been struggling with",
            "what's been decaying",
            "let's get back on track",
            "executive function",
            "executive dysfunction",
        ]
        for copy in allCopyKeys {
            let lowered = copy.lowercased()
            for tok in banned {
                XCTAssertFalse(lowered.contains(tok),
                               "Banned v2 §8 token '\(tok)' appears in: \"\(copy)\"")
            }
            // §8 also bans exclamation marks anywhere in coordinator copy.
            XCTAssertFalse(copy.contains("!"),
                           "Exclamation mark in coordinator copy: \"\(copy)\"")
        }
    }

    // MARK: - PromptAssembler integration

    private func makeRuntime(
        branch: EmptyStateBranch?,
        state: ConversationState
    ) -> RuntimeContext {
        return RuntimeContext(
            now: Date(timeIntervalSince1970: 1_715_900_000), // mid-day
            localTimezone: TimeZone(identifier: "America/New_York")!,
            conversationState: state,
            emptyStateBranch: branch,
            mercyMode: .off,
            pauseUntil: nil,
            activeDomains: [],
            openCommitments: [],
            recentEventsSummary: nil,
            memoryHitsSummary: nil,
            todayCalendarSummary: nil,
            userMessage: "test",
            priorTurnSummary: nil
        )
    }

    func test_assembledPrompt_branchA_carriesVerbatimOfferTemplates() {
        let prompt = PromptAssembler().assemble(
            for: .coordinator,
            runtime: makeRuntime(branch: .branchACaptureFirst, state: .capturedAwaitingTrackOffer),
            scope: .coordinatorAll
        )
        XCTAssertTrue(prompt.text.contains("empty_state_copy_templates:"))
        XCTAssertTrue(prompt.text.contains("Want me to start keeping sleep for you"))
        XCTAssertTrue(prompt.text.contains("Cool. I'll keep the log either way"))
    }

    func test_assembledPrompt_branchB_carriesVerbatimSetupTemplates() {
        let prompt = PromptAssembler().assemble(
            for: .coordinator,
            runtime: makeRuntime(branch: .branchBSetupFirst, state: .awaitingLifeAreaAnswer),
            scope: .coordinatorAll
        )
        XCTAssertTrue(prompt.text.contains("what's one thing you'd like me to help carry"))
        XCTAssertTrue(prompt.text.contains("How should it act"))
        XCTAssertTrue(prompt.text.contains("sleep hours, 7-day average"))
    }

    func test_assembledPrompt_branchC_carriesVerbatimOnRamp() {
        let prompt = PromptAssembler().assemble(
            for: .coordinator,
            runtime: makeRuntime(branch: .branchCUnclear, state: .unclearOnRamp),
            scope: .coordinatorAll
        )
        XCTAssertTrue(prompt.text.contains("No worries. Easiest start"))
        XCTAssertTrue(prompt.text.contains("tell me one thing about today"))
    }

    func test_assembledPrompt_noBranch_doesNotEmitVerbatimTemplates() {
        // The role_prompt body REFERENCES `empty_state_copy_templates:` as
        // a key name (instructing the LLM where to look) even when no
        // branch is active — so checking that string is too strict. The
        // right assertion: the actual verbatim TEMPLATE strings are absent.
        let prompt = PromptAssembler().assemble(
            for: .coordinator,
            runtime: makeRuntime(branch: nil, state: .inFreeChat),
            scope: .coordinatorAll
        )
        XCTAssertFalse(prompt.text.contains("Want me to start keeping sleep for you"))
        XCTAssertFalse(prompt.text.contains("what's one thing you'd like me to help carry"))
        XCTAssertFalse(prompt.text.contains("No worries. Easiest start"))
    }

    func test_rolePrompt_instructsLLMToUseVerbatimTemplates() {
        let prompt = PromptAssembler().assemble(
            for: .coordinator,
            runtime: makeRuntime(branch: .branchBSetupFirst, state: .awaitingLifeAreaAnswer),
            scope: .coordinatorAll
        )
        XCTAssertTrue(prompt.text.contains("verbatim copy templates"))
        XCTAssertTrue(prompt.text.contains("stay on-script"))
    }
}
