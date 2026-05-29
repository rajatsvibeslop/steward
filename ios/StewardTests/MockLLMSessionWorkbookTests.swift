//
//  MockLLMSessionWorkbookTests.swift
//  StewardTests
//
//  Pins the mock plans + intent parsers added so the sim can drive the
//  workbook pipeline end-to-end (Foundation Models doesn't run on
//  x86_64 sim). The agent loop + tools are tested separately; these
//  assertions cover the deterministic dispatch on user phrases.
//

import XCTest
@testable import Steward

final class MockLLMSessionWorkbookTests: XCTestCase {

    // MARK: - parseTrackIntent

    func test_parseTrackIntent_matchesTrackMyX() {
        XCTAssertEqual(MockResponsePlan.parseTrackIntent("track my sleep"), "sleep")
        XCTAssertEqual(MockResponsePlan.parseTrackIntent("track my workouts"), "workouts")
    }

    func test_parseTrackIntent_matchesStartTrackingX() {
        XCTAssertEqual(MockResponsePlan.parseTrackIntent("start tracking weight"), "weight")
        XCTAssertEqual(MockResponsePlan.parseTrackIntent("let's track money"), "money")
    }

    func test_parseTrackIntent_stripsLeadingArticles() {
        XCTAssertEqual(MockResponsePlan.parseTrackIntent("track the food"), "food")
        XCTAssertEqual(MockResponsePlan.parseTrackIntent("track my workouts"), "workouts")
    }

    func test_parseTrackIntent_stopsAtPunctuation() {
        XCTAssertEqual(
            MockResponsePlan.parseTrackIntent("track my sleep, please"),
            "sleep"
        )
    }

    func test_parseTrackIntent_nilOnNonTrackPhrase() {
        XCTAssertNil(MockResponsePlan.parseTrackIntent("how am i doing"))
        XCTAssertNil(MockResponsePlan.parseTrackIntent("hello there"))
    }

    // MARK: - parseWebSearchIntent

    func test_parseWebSearchIntent_pullsQueryAfterTrigger() {
        XCTAssertEqual(
            MockResponsePlan.parseWebSearchIntent("search for the xerus species"),
            "the xerus species"
        )
        XCTAssertEqual(
            MockResponsePlan.parseWebSearchIntent("look up macronutrients"),
            "macronutrients"
        )
        XCTAssertEqual(
            MockResponsePlan.parseWebSearchIntent("who is alan kay?"),
            "alan kay"
        )
    }

    func test_parseWebSearchIntent_nilOnNoTrigger() {
        XCTAssertNil(MockResponsePlan.parseWebSearchIntent("track my sleep"))
    }

    // MARK: - sheet.create dispatch

    private static let freeChatPrompt = "conversation_state: free_chat"

    func test_trackSleep_emitsSheetCreateWithSleepSchema() throws {
        let plan = MockResponsePlan.plan(
            systemPrompt: Self.freeChatPrompt,
            userMessage: "track my sleep"
        )
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.sheetCreate.rawValue)
        let args = try ToolJSON.decode(SheetCreateArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.displayName, "Sleep")
        XCTAssertEqual(args.columns.map(\.name), ["date", "hours", "notes"])
        XCTAssertEqual(args.columns.map(\.kind), [.date, .number, .text])
        XCTAssertEqual(args.actor, "coordinator")
    }

    func test_trackMoney_emitsSheetCreateWithCurrencyColumn() throws {
        let plan = MockResponsePlan.plan(
            systemPrompt: Self.freeChatPrompt,
            userMessage: "let's track money"
        )
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.sheetCreate.rawValue)
        let args = try ToolJSON.decode(SheetCreateArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.displayName, "Money")
        XCTAssertTrue(args.columns.contains { $0.kind == .currency })
    }

    func test_trackUnknownTopic_emitsGenericSchema() throws {
        let plan = MockResponsePlan.plan(
            systemPrompt: Self.freeChatPrompt,
            userMessage: "track my journaling"
        )
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.sheetCreate.rawValue)
        let args = try ToolJSON.decode(SheetCreateArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.displayName, "Journaling")
        XCTAssertEqual(args.columns.map(\.name), ["date", "value", "notes"])
    }

    // MARK: - web.search dispatch

    func test_searchFor_emitsWebSearchToolCall() throws {
        let plan = MockResponsePlan.plan(
            systemPrompt: Self.freeChatPrompt,
            userMessage: "search for xerus"
        )
        let call = try XCTUnwrap(plan.toolCalls.first)
        XCTAssertEqual(call.toolID, ToolID.webSearch.rawValue)
        let args = try ToolJSON.decode(WebSearchArgs.self, from: call.argsJSON)
        XCTAssertEqual(args.query, "xerus")
    }
}
