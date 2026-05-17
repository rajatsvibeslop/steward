//
//  EmptyStateRouterTests.swift
//  StewardTests — Track B
//
//  Determinism + branch coverage for the pre-LLM router.
//

import XCTest
@testable import Steward

final class EmptyStateRouterTests: XCTestCase {

    // MARK: - Determinism

    func test_sameInput_alwaysSameBranch_branchA() {
        let input = "slept 6 hours and weight is 178"
        let first = EmptyStateRouter.route(input)
        for _ in 0..<32 {
            XCTAssertEqual(EmptyStateRouter.route(input), first)
        }
        XCTAssertEqual(first, .branchACaptureFirst)
    }

    func test_sameInput_alwaysSameBranch_branchB() {
        let input = "walk me through it"
        let first = EmptyStateRouter.route(input)
        for _ in 0..<32 {
            XCTAssertEqual(EmptyStateRouter.route(input), first)
        }
        XCTAssertEqual(first, .branchBSetupFirst)
    }

    func test_sameInput_alwaysSameBranch_branchC() {
        let input = "hi"
        let first = EmptyStateRouter.route(input)
        for _ in 0..<32 {
            XCTAssertEqual(EmptyStateRouter.route(input), first)
        }
        XCTAssertEqual(first, .branchCUnclear)
    }

    // MARK: - Branch B: setup intent phrases

    func test_branchB_walkMeThroughIt() {
        XCTAssertEqual(EmptyStateRouter.route("walk me through it"), .branchBSetupFirst)
    }

    func test_branchB_caseAndWhitespaceTolerant() {
        XCTAssertEqual(EmptyStateRouter.route("  Walk Me Through It  "), .branchBSetupFirst)
        XCTAssertEqual(EmptyStateRouter.route("WHERE DO I START"), .branchBSetupFirst)
        XCTAssertEqual(EmptyStateRouter.route("how does this work"), .branchBSetupFirst)
    }

    func test_branchB_allSetupIntentPhrases() {
        let phrases = [
            "walk me through it", "walk me through this", "set me up",
            "help me start", "help me set up", "set up", "setup",
            "i don't know where to start", "where do i start",
            "how does this work", "what do i do",
        ]
        for phrase in phrases {
            XCTAssertEqual(EmptyStateRouter.route(phrase), .branchBSetupFirst,
                           "phrase '\(phrase)' should route to Branch B")
        }
    }

    // MARK: - Branch C: monosyllabic / greeting

    func test_branchC_singleGreetings() {
        let greetings = ["hi", "hey", "hello", "yo", "sup", "morning", "ok", "okay", "k"]
        for g in greetings {
            XCTAssertEqual(EmptyStateRouter.route(g), .branchCUnclear,
                           "greeting '\(g)' should route to Branch C")
        }
    }

    func test_branchC_twoWordsRoutesToC() {
        XCTAssertEqual(EmptyStateRouter.route("hi there"), .branchCUnclear)
        XCTAssertEqual(EmptyStateRouter.route("good morning"), .branchCUnclear)
    }

    func test_branchC_emptyInputRoutesToC() {
        XCTAssertEqual(EmptyStateRouter.route(""), .branchCUnclear)
        XCTAssertEqual(EmptyStateRouter.route("   "), .branchCUnclear)
    }

    // MARK: - Branch A: concrete capture

    func test_branchA_concreteCaptures() {
        let captures = [
            "slept 6 hours and weight is 178",
            "spent $80 on groceries",
            "i bed-rotted today and need to do laundry",
            "ate breakfast and went for a walk",
        ]
        for c in captures {
            XCTAssertEqual(EmptyStateRouter.route(c), .branchACaptureFirst,
                           "capture '\(c)' should route to Branch A")
        }
    }

    // MARK: - Edge cases

    func test_setupIntentBeatsWordCount() {
        // "set up" is two words but it's a setup-intent phrase, so it
        // takes B even though it would otherwise fall to C by wordCount<3.
        XCTAssertEqual(EmptyStateRouter.route("set up"), .branchBSetupFirst)
    }

    func test_normalize_collapsesWhitespace() {
        XCTAssertEqual(
            EmptyStateRouter.normalize("  walk    me\nthrough  it  "),
            "walk me through it"
        )
    }
}
