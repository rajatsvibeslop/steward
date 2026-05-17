//
//  ToolGuardTests.swift
//  StewardTests
//
//  ToolScope + ToolGuard validation. The guard rejects out-of-scope tools
//  and pinned-arg violations. Pod B's actual API takes pre-parsed
//  `[String: AnyCodableScalar]` args (not a JSON string) and throws
//  `ToolGuardError.toolOutOfScope` / `.argPinViolation`.
//

import XCTest
@testable import Steward

final class ToolGuardTests: XCTestCase {

    func test_coordinatorScope_allowsEverything() throws {
        let scope = ToolScope.coordinatorAll
        // event.capture is allowed under the coordinator scope; should
        // validate without throwing.
        try ToolGuard.validate(
            .eventCapture,
            args: [
                "text": .string("hi"),
                "reasoning": .string("r"),
                "actor": .string("coordinator")
            ],
            scope: scope
        )
    }

    func test_domainScope_pinsDomainArg_acceptsMatchingDomain() throws {
        let scope = ToolScope.domain("money")
        try ToolGuard.validate(
            .eventCapture,
            args: [
                "text": .string("spent"),
                "domain": .string("money"),
                "reasoning": .string("r"),
                "actor": .string("agent:money")
            ],
            scope: scope
        )
    }

    func test_domainScope_rejectsConflictingDomain() {
        let scope = ToolScope.domain("money")
        XCTAssertThrowsError(try ToolGuard.validate(
            .eventCapture,
            args: [
                "text": .string("spent"),
                "domain": .string("health"),
                "reasoning": .string("r"),
                "actor": .string("agent:money")
            ],
            scope: scope
        )) { error in
            guard case ToolGuardError.argPinViolation(_, let arg, _) = error else {
                XCTFail("expected argPinViolation; got \(error)"); return
            }
            XCTAssertEqual(arg, "domain")
        }
    }

    func test_disallowedTool_rejected() {
        let scope = ToolScope.domain("money")  // does NOT include mercyModeEngage
        XCTAssertThrowsError(try ToolGuard.validate(
            .mercyModeEngage,
            args: [:],
            scope: scope
        )) { error in
            guard case ToolGuardError.toolOutOfScope = error else {
                XCTFail("expected toolOutOfScope; got \(error)"); return
            }
        }
    }
}
