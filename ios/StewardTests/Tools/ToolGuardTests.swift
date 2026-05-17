//
//  ToolGuardTests.swift
//  StewardTests
//
//  ToolScope + ToolGuard validation. The guard rewrites pinned args and
//  rejects whitelist violations / disallowed tools.
//

import XCTest
@testable import Steward

final class ToolGuardTests: XCTestCase {

    func test_coordinatorScope_allowsEverything() throws {
        let scope = ToolScope.coordinator
        let rewritten = try ToolGuard.validate(
            .eventCapture,
            argsJSON: #"{"text":"hi","reasoning":"r","actor":"coordinator"}"#,
            scope: scope
        )
        XCTAssertFalse(rewritten.isEmpty)
    }

    func test_domainScope_pinsDomainArgWhenAbsent() throws {
        let scope = ToolScope.domain("money")
        let rewritten = try ToolGuard.validate(
            .eventCapture,
            argsJSON: #"{"text":"spent","reasoning":"r","actor":"agent:money"}"#,
            scope: scope
        )
        XCTAssertTrue(rewritten.contains("\"domain\":\"money\""), "rewritten args should pin domain → got \(rewritten)")
    }

    func test_domainScope_rejectsConflictingDomain() {
        let scope = ToolScope.domain("money")
        XCTAssertThrowsError(try ToolGuard.validate(
            .eventCapture,
            argsJSON: #"{"text":"spent","domain":"health","reasoning":"r","actor":"agent:money"}"#,
            scope: scope
        )) { error in
            guard case ToolGuardError.fixedArgConflict(let arg, _, _) = error else {
                XCTFail("expected fixedArgConflict; got \(error)"); return
            }
            XCTAssertEqual(arg, "domain")
        }
    }

    func test_disallowedTool_rejected() {
        let scope = ToolScope.domain("money")  // does NOT allow mercy_mode.engage
        XCTAssertThrowsError(try ToolGuard.validate(
            .mercyModeEngage,
            argsJSON: "{}",
            scope: scope
        )) { error in
            guard case ToolGuardError.toolNotAllowed = error else {
                XCTFail("expected toolNotAllowed; got \(error)"); return
            }
        }
    }
}
