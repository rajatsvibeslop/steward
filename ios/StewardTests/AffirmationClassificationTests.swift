//
//  AffirmationClassificationTests.swift
//  StewardTests — Track B (deslop S2)
//
//  Confirms `AgentLoop.classifyAffirmation` tokenizes properly and is not
//  fooled by substring matches like "no okay" or "yeah no".
//

import XCTest
@testable import Steward

final class AffirmationClassificationTests: XCTestCase {

    typealias C = AgentLoop.AffirmationClassification

    // MARK: - Affirmative

    func test_singleWordAffirmatives() {
        XCTAssertEqual(AgentLoop.classifyAffirmation("yes"), .affirmative)
        XCTAssertEqual(AgentLoop.classifyAffirmation("Yeah"), .affirmative)
        XCTAssertEqual(AgentLoop.classifyAffirmation("yep!"), .affirmative)
        XCTAssertEqual(AgentLoop.classifyAffirmation("ok"), .affirmative)
        XCTAssertEqual(AgentLoop.classifyAffirmation("okay"), .affirmative)
        XCTAssertEqual(AgentLoop.classifyAffirmation("confirm"), .affirmative)
        XCTAssertEqual(AgentLoop.classifyAffirmation("sure"), .affirmative)
    }

    func test_multiWordAffirmatives() {
        XCTAssertEqual(AgentLoop.classifyAffirmation("sounds good"), .affirmative)
        XCTAssertEqual(AgentLoop.classifyAffirmation("do it"), .affirmative)
        XCTAssertEqual(AgentLoop.classifyAffirmation("Let's do it"), .affirmative)
    }

    func test_trailingWordsDontPoisonAffirmative() {
        XCTAssertEqual(AgentLoop.classifyAffirmation("yes please"), .affirmative)
        XCTAssertEqual(AgentLoop.classifyAffirmation("yeah let's go"), .affirmative)
    }

    // MARK: - Refusal — the bugs deslop S2 caught

    func test_refusal_substringBugFixed_noOkay() {
        // BUG: previous impl matched "ok" as affirmative substring in "no okay"
        XCTAssertEqual(AgentLoop.classifyAffirmation("no okay"), .refusal)
    }

    func test_refusal_substringBugFixed_yeahNo() {
        // BUG: previous impl matched "yeah" in "yeah no"
        XCTAssertEqual(AgentLoop.classifyAffirmation("yeah no"), .refusal)
    }

    func test_refusal_simpleNoForms() {
        XCTAssertEqual(AgentLoop.classifyAffirmation("no"), .refusal)
        XCTAssertEqual(AgentLoop.classifyAffirmation("nope"), .refusal)
        XCTAssertEqual(AgentLoop.classifyAffirmation("nah"), .refusal)
        XCTAssertEqual(AgentLoop.classifyAffirmation("skip"), .refusal)
        XCTAssertEqual(AgentLoop.classifyAffirmation("stop"), .refusal)
        XCTAssertEqual(AgentLoop.classifyAffirmation("don't"), .refusal)
    }

    func test_refusal_punctuated() {
        XCTAssertEqual(AgentLoop.classifyAffirmation("No."), .refusal)
        XCTAssertEqual(AgentLoop.classifyAffirmation("No, thanks!"), .refusal)
    }

    // MARK: - Unclear

    func test_unclear_blankAndAmbiguous() {
        XCTAssertEqual(AgentLoop.classifyAffirmation(""), .unclear)
        XCTAssertEqual(AgentLoop.classifyAffirmation("   "), .unclear)
        XCTAssertEqual(AgentLoop.classifyAffirmation("maybe"), .unclear)
        XCTAssertEqual(AgentLoop.classifyAffirmation("I'll think about it"), .unclear)
    }
}
