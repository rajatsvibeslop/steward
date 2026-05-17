//
//  TurnBudgetTests.swift
//  StewardTests — Track B
//

import XCTest
@testable import Steward

final class TurnBudgetTests: XCTestCase {

    func test_consume8Succeeds_consume9Throws() throws {
        var budget = TurnBudget(
            handoffsRemaining: TurnBudget.defaultHandoffs,
            contextTokenCeiling: TurnBudget.coordinatorTokenCeiling,
            startedAt: Date()
        )
        for _ in 0..<8 {
            XCTAssertNoThrow(try budget.consumeHandoff())
        }
        XCTAssertEqual(budget.handoffsRemaining, 0)
        XCTAssertThrowsError(try budget.consumeHandoff()) { error in
            XCTAssertEqual(error as? AgentError, .handoffBudgetExhausted)
        }
    }

    func test_zeroBudget_immediatelyThrows() {
        var budget = TurnBudget(
            handoffsRemaining: 0,
            contextTokenCeiling: 9_000,
            startedAt: Date()
        )
        XCTAssertThrowsError(try budget.consumeHandoff()) { error in
            XCTAssertEqual(error as? AgentError, .handoffBudgetExhausted)
        }
    }

    func test_defaultsMatchAddendum() {
        XCTAssertEqual(TurnBudget.defaultHandoffs, 8)
        XCTAssertEqual(TurnBudget.coordinatorTokenCeiling, 9_000)
        XCTAssertEqual(TurnBudget.domainTokenCeiling, 6_000)
    }
}
