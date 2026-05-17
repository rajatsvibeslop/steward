//
//  ToolFamilyTests.swift
//  StewardTests
//
//  Smoke tests one tool per family — each tool emits an event with the
//  reasoning field populated (hard reject #11) and round-trips through
//  GRDB. We don't exercise every flag of every tool here; per-family deeper
//  tests live alongside their respective layer (instruments + memory
//  already covered separately).
//

import XCTest
import GRDB
@testable import Steward

final class ToolFamilyTests: XCTestCase {

    private func makeProvider() async throws -> DatabaseProvider {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("steward.sqlite")
        let provider = DatabaseProvider(location: .file(url))
        _ = try await provider.database()
        InstrumentRegistry._resetForTesting()
        InstrumentRegistry.bootstrapAll()
        return provider
    }

    private let fixedNow = ISO8601DateFormatter().date(from: "2026-05-17T10:00:00Z")!

    // MARK: - event.capture

    func test_eventCapture_writesRowWithReasoning() async throws {
        let provider = try await makeProvider()
        let tool = EventCaptureTool(provider: provider, now: { self.fixedNow })
        let args = """
        {
          "text": "drank 16oz water",
          "domain": "health",
          "kind": "log",
          "payload_json": null,
          "reasoning": "user reported a water intake event",
          "actor": "agent:health"
        }
        """
        let resultJSON = try await tool.invoke(argsJSON: args)
        let result = try ToolJSON.decode(EventCaptureResult.self, from: resultJSON)
        XCTAssertFalse(result.eventID.rawValue.isEmpty)

        let db = try await provider.database()
        let row = try await db.read { db -> Row? in
            try Row.fetchOne(db, sql: "SELECT actor, reasoning FROM events WHERE event_id = ?",
                             arguments: [result.eventID])
        }
        XCTAssertEqual(row?["actor"] as String?, "agent:health")
        XCTAssertNotNil(row?["reasoning"] as String?)
    }

    func test_eventCapture_rejectsAgentActorWithoutReasoning() async throws {
        let provider = try await makeProvider()
        let tool = EventCaptureTool(provider: provider, now: { self.fixedNow })
        let args = """
        {
          "text": "missing reasoning",
          "reasoning": "",
          "actor": "coordinator"
        }
        """
        do {
            _ = try await tool.invoke(argsJSON: args)
            XCTFail("should have thrown — coordinator actor requires reasoning")
        } catch {
            // Expected — EventLogError.reasoningRequired surfaces up.
        }
    }

    // MARK: - instrument.create + apply_event

    func test_instrumentLifecycle_createApplyRead() async throws {
        let provider = try await makeProvider()
        let createTool = InstrumentCreateTool(provider: provider, now: { self.fixedNow })
        let applyTool = InstrumentApplyEventTool(provider: provider, now: { self.fixedNow })
        let readTool = InstrumentReadTool(provider: provider)

        let defJSON = """
        {"unit":"USD","period":"daily","limit":100,"rollover":false}
        """
        let createArgs = """
        {
          "kind": "bounded_budget",
          "name": "Discretionary",
          "domain": "money",
          "definition_json": \(defJSON.toJSONString()),
          "review_cadence": null,
          "reasoning": "user asked to track discretionary spend",
          "actor": "agent:money"
        }
        """
        let createResultJSON = try await createTool.invoke(argsJSON: createArgs)
        let createResult = try ToolJSON.decode(InstrumentCreateResult.self, from: createResultJSON)
        XCTAssertEqual(createResult.kind, "bounded_budget")

        let payloadJSON = #"{"value":40,"notes":"lunch"}"#
        let applyArgs = """
        {
          "instrument_id": "\(createResult.instrumentID)",
          "event_kind": "spend",
          "payload_json": \(payloadJSON.toJSONString()),
          "notes": "lunch",
          "reasoning": "user logged a $40 lunch spend",
          "actor": "agent:money"
        }
        """
        _ = try await applyTool.invoke(argsJSON: applyArgs)

        let readResultJSON = try await readTool.invoke(
            argsJSON: #"{"instrument_id":"\#(createResult.instrumentID)"}"#
        )
        let readResult = try ToolJSON.decode(InstrumentReadResult.self, from: readResultJSON)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let state = try dec.decode(BoundedBudget.State.self, from: readResult.stateJSON.data(using: .utf8)!)
        XCTAssertEqual(state.periodTotal, 40)
        XCTAssertEqual(state.remaining, 60)
    }

    // MARK: - commitment

    func test_commitmentCreateAndComplete() async throws {
        let provider = try await makeProvider()
        let create = CommitmentCreateTool(provider: provider, now: { self.fixedNow })
        let createArgs = """
        {
          "title": "Call dentist",
          "domain": "health",
          "due_at": null,
          "importance": "medium",
          "linked_instrument_id": null,
          "reasoning": "user mentioned they need to schedule a cleaning",
          "actor": "agent:health"
        }
        """
        let cResultJSON = try await create.invoke(argsJSON: createArgs)
        let cResult = try ToolJSON.decode(CommitmentCreateResult.self, from: cResultJSON)
        XCTAssertFalse(cResult.commitmentID.rawValue.isEmpty)

        let complete = CommitmentCompleteTool(provider: provider, now: { self.fixedNow })
        let doneArgs = """
        {
          "commitment_id": "\(cResult.commitmentID)",
          "notes": "scheduled for next Tuesday",
          "reasoning": "user reported done",
          "actor": "agent:health"
        }
        """
        let dResultJSON = try await complete.invoke(argsJSON: doneArgs)
        let dResult = try ToolJSON.decode(CommitmentTransitionResult.self, from: dResultJSON)
        XCTAssertEqual(dResult.status, .done)
    }

    // MARK: - settings

    func test_mercyMode_engageMutatesSettings() async throws {
        let provider = try await makeProvider()
        // Bind SettingsStore to the same provider as the tool would in prod.
        let settings = SettingsStore(provider: provider)
        let tool = MercyModeEngageTool(provider: provider, settings: settings, now: { self.fixedNow })
        let until = ISO8601DateFormatter().string(from: self.fixedNow.addingTimeInterval(3600))
        let args = """
        {
          "until_when": "\(until)",
          "reason": "user said they're overwhelmed",
          "reasoning": "user explicitly asked to dial back the nudges for an hour",
          "actor": "coordinator"
        }
        """
        _ = try await tool.invoke(argsJSON: args)

        let s = try await settings.load()
        XCTAssertNotNil(s.mercyModeUntil)
    }

    // MARK: - domain

    func test_domainCreate_seedsToolScopeWhenUnspecified() async throws {
        let provider = try await makeProvider()
        let tool = DomainCreateTool(provider: provider, now: { self.fixedNow })
        let args = """
        {
          "domain": "creative",
          "display_name": "Creative",
          "role_prompt": "You are the Creative agent.",
          "tool_scope_json": null,
          "default_quiet_hours": null,
          "reasoning": "user asked to spawn a creative-projects team",
          "actor": "coordinator"
        }
        """
        _ = try await tool.invoke(argsJSON: args)
        let db = try await provider.database()
        try await db.read { db in
            let scopeJSON = try String.fetchOne(db, sql: "SELECT tool_scope_json FROM domains WHERE domain = 'creative'")
            XCTAssertNotNil(scopeJSON)
            XCTAssertTrue(scopeJSON!.contains("\"allowedTools\""))
        }
    }
}

// MARK: - Test helpers

private extension String {
    /// Escape `self` as a JSON string literal (so it can be embedded inside a
    /// larger JSON args blob in tests). Simple — no surrogate handling.
    func toJSONString() -> String {
        var out = "\""
        for c in self {
            switch c {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default: out.append(c)
            }
        }
        out.append("\"")
        return out
    }
}
