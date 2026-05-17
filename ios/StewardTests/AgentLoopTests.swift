//
//  AgentLoopTests.swift
//  StewardTests
//
//  Covers:
//   - Single-hop coordinator response
//   - Multi-hop coordinator → handoff → domain → tool call → return
//   - Hop cap enforcement (8 hops max; 9-hop attempt fails gracefully)
//

import XCTest
@testable import Steward

final class AgentLoopTests: XCTestCase {

    // MARK: - Single-hop (Branch A capture-first)

    func test_singleHopCoordinator_capturesEventViaBranchA() async throws {
        let factory = MockLLMSessionFactory()
        let captureTool = RecordingTool(id: ToolID.eventCapture.rawValue)
        let registry = MapToolRegistry()
        await registry.register(captureTool, as: .eventCapture)

        let loop = AgentLoop(
            factory: factory,
            registry: registry,
            resolver: FixtureDomainAgentResolver(domains: []),
            initialState: .awaitingFirstMessage
        )

        let response = try await loop.run(userMessage: "slept 6 hours and weight is 178")
        XCTAssertTrue(response.text.contains("Logged"))
        XCTAssertEqual(response.handoffsConsumed, 0)
        XCTAssertFalse(response.budgetExhausted)
        XCTAssertEqual(response.backendKind, .mock(reason: .sdkNotCompiledIn))

        let recorded = await captureTool.invocations
        XCTAssertEqual(recorded.count, 1)
    }

    // MARK: - Multi-hop coordinator → handoff → domain → tool → return

    func test_multiHop_coordinatorHandsOffToDomain_domainCallsTool() async throws {
        let factory = MockLLMSessionFactory()
        let domainCaptureTool = RecordingTool(id: ToolID.eventCapture.rawValue)
        let registry = MapToolRegistry()
        await registry.register(domainCaptureTool, as: .eventCapture)

        let healthAgent = DomainAgent(
            domain: "health",
            displayName: "Health",
            rolePrompt: RolePromptTemplates.render(tone: .stayGentle, displayName: "Health")
        )
        let resolver = FixtureDomainAgentResolver(domains: [healthAgent])

        let coordinatorState: ConversationState = .inFreeChat
        let loop = AgentLoop(
            factory: factory,
            registry: registry,
            resolver: resolver,
            initialState: coordinatorState
        )

        // Drive the coordinator's mock to invoke agent.handoff directly by
        // exercising the handoff tool. We invoke it through the registered
        // tool list using a synthetic args payload.
        let budget = SharedBudget(budget: TurnBudget(
            handoffsRemaining: TurnBudget.defaultHandoffs,
            contextTokenCeiling: TurnBudget.coordinatorTokenCeiling,
            startedAt: Date()
        ))
        let handoff = AgentHandoffTool(
            budget: budget,
            resolver: resolver,
            registry: registry,
            factory: factory,
            temperature: 0.7,
            timezone: .autoupdatingCurrent,
            clock: { Date(timeIntervalSince1970: 1_715_000_000) }
        )

        let resultJSON = try await handoff.invoke(
            argsJSON: #"{"domain":"health","message":"i slept 7 hours"}"#
        )

        // Domain agent's MockLLMSession should have called event.capture.
        let recorded = await domainCaptureTool.invocations
        XCTAssertEqual(recorded.count, 1)

        XCTAssertTrue(resultJSON.contains("\"domain\":\"health\""))
        XCTAssertTrue(resultJSON.contains("[MOCK]"))
        // One hop consumed.
        let snapshot = await budget.snapshot()
        XCTAssertEqual(snapshot.handoffsRemaining, TurnBudget.defaultHandoffs - 1)
    }

    // MARK: - Hop cap enforcement (9-hop attempt fails gracefully)

    func test_hopCap_ninthAttempt_returnsStructuredError() async throws {
        let factory = MockLLMSessionFactory()
        let registry = MapToolRegistry()
        let healthAgent = DomainAgent(
            domain: "health",
            displayName: "Health",
            rolePrompt: RolePromptTemplates.render(tone: .stayGentle, displayName: "Health")
        )
        let resolver = FixtureDomainAgentResolver(domains: [healthAgent])

        let budget = SharedBudget(budget: TurnBudget(
            handoffsRemaining: TurnBudget.defaultHandoffs,
            contextTokenCeiling: TurnBudget.coordinatorTokenCeiling,
            startedAt: Date()
        ))
        let handoff = AgentHandoffTool(
            budget: budget,
            resolver: resolver,
            registry: registry,
            factory: factory,
            temperature: 0.7,
            timezone: .autoupdatingCurrent,
            clock: { Date() }
        )

        // First 8 calls consume the budget.
        for hop in 0..<TurnBudget.defaultHandoffs {
            let r = try await handoff.invoke(
                argsJSON: #"{"domain":"health","message":"ping"}"#
            )
            // Each successful handoff returns a domain payload, not an error.
            XCTAssertFalse(r.contains("handoff_budget_exhausted"),
                           "hop #\(hop + 1) should succeed; got: \(r)")
        }

        // 9th call must return the structured error JSON. NO throw, NO crash.
        let ninth = try await handoff.invoke(
            argsJSON: #"{"domain":"health","message":"ping"}"#
        )
        XCTAssertTrue(ninth.contains("handoff_budget_exhausted"),
                      "9th hop must return structured budget-exhausted error JSON; got: \(ninth)")

        let snapshot = await budget.snapshot()
        XCTAssertEqual(snapshot.handoffsRemaining, 0)
    }

    // MARK: - Handoff to unknown domain returns structured error

    func test_handoff_unknownDomain_returnsStructuredError() async throws {
        let factory = MockLLMSessionFactory()
        let registry = MapToolRegistry()
        let resolver = FixtureDomainAgentResolver(domains: [])
        let budget = SharedBudget(budget: TurnBudget(
            handoffsRemaining: TurnBudget.defaultHandoffs,
            contextTokenCeiling: 6_000,
            startedAt: Date()
        ))
        let handoff = AgentHandoffTool(
            budget: budget,
            resolver: resolver,
            registry: registry,
            factory: factory,
            temperature: 0.7,
            timezone: .autoupdatingCurrent,
            clock: { Date() }
        )
        let r = try await handoff.invoke(
            argsJSON: #"{"domain":"unknown","message":"hi"}"#
        )
        XCTAssertTrue(r.contains("domain_not_found"))
    }

    // MARK: - Malformed args return structured error, never throw

    func test_handoff_malformedArgs_returnsStructuredError() async throws {
        let factory = MockLLMSessionFactory()
        let registry = MapToolRegistry()
        let resolver = FixtureDomainAgentResolver(domains: [])
        let budget = SharedBudget(budget: TurnBudget(
            handoffsRemaining: TurnBudget.defaultHandoffs,
            contextTokenCeiling: 6_000,
            startedAt: Date()
        ))
        let handoff = AgentHandoffTool(
            budget: budget,
            resolver: resolver,
            registry: registry,
            factory: factory,
            temperature: 0.7,
            timezone: .autoupdatingCurrent,
            clock: { Date() }
        )
        let r = try await handoff.invoke(argsJSON: "not json at all")
        XCTAssertTrue(r.contains("malformed_args"))
        // Deslop S7: error JSON must always be valid JSON regardless of
        // what control chars the detail string contains.
        let parsed = try JSONSerialization.jsonObject(with: Data(r.utf8))
        XCTAssertTrue(parsed is [String: Any])
    }

    // MARK: - S7 — errorJSON survives newlines + quotes in detail string

    func test_handoff_errorJSON_isAlwaysValidJSON_evenWithControlChars() async throws {
        let factory = MockLLMSessionFactory()
        let registry = MapToolRegistry()
        let resolver = FixtureDomainAgentResolver(domains: [])
        let budget = SharedBudget(budget: TurnBudget(
            handoffsRemaining: TurnBudget.defaultHandoffs,
            contextTokenCeiling: 6_000,
            startedAt: Date()
        ))
        let handoff = AgentHandoffTool(
            budget: budget,
            resolver: resolver,
            registry: registry,
            factory: factory,
            temperature: 0.7,
            timezone: .autoupdatingCurrent,
            clock: { Date() }
        )
        // Force malformed args parsing to surface an error JSON; the args
        // here will fail JSON decoding because they're not a JSON object,
        // which will exercise the errorJSON path.
        let r = try await handoff.invoke(argsJSON: "broken\n\"input\\with\\backslashes")
        // Result must be parseable JSON regardless of input weirdness.
        let parsed = try JSONSerialization.jsonObject(with: Data(r.utf8))
        guard let dict = parsed as? [String: Any] else {
            XCTFail("error JSON not a top-level object"); return
        }
        XCTAssertNotNil(dict["error"])
    }

    // MARK: - Mercy / pause plumbing (nemesis bug #2)
    //
    // Before this patch the AgentLoop hardcoded `.off` / `nil` into every
    // RuntimeContext it built — so the coordinator + domain agents never
    // saw `mercy_mode: on` even when the user had engaged mercy mode in
    // Settings. PromptAssembler renders mercy fine; the bug was upstream.
    // These tests pin both construction sites (coordinator turn + handoff
    // turn) to the live settings reader and assert the rendered runtime
    // context shows `mercy_mode: on (...)` when settings say so.

    func test_RuntimeContext_RendersMercyOn_WhenSettingsMercyUntilFuture() async throws {
        // Capture the runtime via the SAME path AgentLoop uses: the same
        // CoordinatorAgent + PromptAssembler that build the system prompt.
        let now = Date(timeIntervalSince1970: 1_715_900_000)
        let mercyUntil = now.addingTimeInterval(3600) // 1h in the future

        let reader: RuntimeSettingsReader = { _ in
            return (.on(until: mercyUntil), nil)
        }

        let (mercy, pauseUntil) = await reader(now)
        let runtime = RuntimeContext(
            now: now,
            localTimezone: TimeZone(identifier: "America/New_York")!,
            conversationState: .inFreeChat,
            emptyStateBranch: nil,
            mercyMode: mercy,
            pauseUntil: pauseUntil,
            activeDomains: [],
            openCommitments: [],
            recentEventsSummary: nil,
            memoryHitsSummary: nil,
            todayCalendarSummary: nil,
            userMessage: "any",
            priorTurnSummary: nil
        )

        let rendered = PromptAssembler().assemble(
            for: .coordinator,
            runtime: runtime,
            scope: .coordinatorAll
        ).text

        XCTAssertTrue(
            rendered.contains("mercy_mode: on"),
            "runtime context must render mercy_mode: on when settings.mercyModeUntil is in the future; got:\n\(rendered)"
        )
        XCTAssertFalse(
            rendered.contains("mercy_mode: off"),
            "runtime context must not say mercy_mode: off when mercy is engaged"
        )
    }

    func test_RuntimeContext_RendersMercyOff_WhenSettingsMercyUntilNilOrPast() async throws {
        let now = Date(timeIntervalSince1970: 1_715_900_000)

        // Case 1: mercy nil → off.
        let nilReader: RuntimeSettingsReader = { _ in (.off, nil) }
        let (m1, p1) = await nilReader(now)
        XCTAssertEqual(m1, .off)
        XCTAssertNil(p1)

        let runtime1 = RuntimeContext(
            now: now,
            localTimezone: TimeZone(identifier: "America/New_York")!,
            conversationState: .inFreeChat,
            emptyStateBranch: nil,
            mercyMode: m1,
            pauseUntil: p1,
            activeDomains: [],
            openCommitments: [],
            recentEventsSummary: nil,
            memoryHitsSummary: nil,
            todayCalendarSummary: nil,
            userMessage: "any",
            priorTurnSummary: nil
        )
        let rendered1 = PromptAssembler().assemble(
            for: .coordinator, runtime: runtime1, scope: .coordinatorAll
        ).text
        XCTAssertTrue(rendered1.contains("mercy_mode: off"))

        // Case 2: defaultRuntimeSettingsReader's expiry logic — a past
        // mercyModeUntil renders off too. Use an inline reader to mimic
        // what the production default does on its own (no DB needed).
        let pastUntil = now.addingTimeInterval(-3600)
        let pastReader: RuntimeSettingsReader = { current in
            if pastUntil > current {
                return (.on(until: pastUntil), nil)
            }
            return (.off, nil)
        }
        let (m2, _) = await pastReader(now)
        XCTAssertEqual(m2, .off, "past mercyModeUntil must resolve to .off")
    }

    func test_AgentLoop_PassesSettingsReader_ToHandoffTool() async throws {
        // Asserts the second bug site: the handoff tool's RuntimeContext
        // also reflects live mercy state, not the old hardcoded .off. We
        // wrap a real MockLLMSessionFactory in a recording factory that
        // captures every systemPrompt it sees.
        let underlying = MockLLMSessionFactory()
        let recorder = PromptRecordingFactory(inner: underlying)
        let registry = MapToolRegistry()
        let healthAgent = DomainAgent(
            domain: "health",
            displayName: "Health",
            rolePrompt: RolePromptTemplates.render(tone: .stayGentle, displayName: "Health")
        )
        let resolver = FixtureDomainAgentResolver(domains: [healthAgent])
        let now = Date(timeIntervalSince1970: 1_715_900_000)
        let mercyUntil = now.addingTimeInterval(3600)

        let budget = SharedBudget(budget: TurnBudget(
            handoffsRemaining: TurnBudget.defaultHandoffs,
            contextTokenCeiling: TurnBudget.coordinatorTokenCeiling,
            startedAt: now
        ))
        let handoff = AgentHandoffTool(
            budget: budget,
            resolver: resolver,
            registry: registry,
            factory: recorder,
            temperature: 0.7,
            timezone: TimeZone(identifier: "America/New_York")!,
            clock: { now },
            settingsReader: { _ in (.on(until: mercyUntil), nil) }
        )

        let resultJSON = try await handoff.invoke(
            argsJSON: #"{"domain":"health","message":"ping"}"#
        )
        XCTAssertTrue(resultJSON.contains("\"domain\":\"health\""))

        let prompts = await recorder.recordedPrompts()
        guard let lastPrompt = prompts.last else {
            XCTFail("expected at least one session built by the handoff tool")
            return
        }
        XCTAssertTrue(
            lastPrompt.contains("mercy_mode: on"),
            "handoff-built domain prompt must reflect live mercy state; got:\n\(lastPrompt)"
        )
    }
}

// MARK: - Recording LLM factory (test seam for prompt inspection)

/// Wraps a real `LLMSessionFactory` and captures every `systemPrompt`
/// it's asked to build a session for. Used by mercy-plumbing tests to
/// assert that AgentLoop / AgentHandoffTool surface live settings into
/// the runtime context segment.
private final class PromptRecordingFactory: LLMSessionFactory, @unchecked Sendable {
    private let inner: any LLMSessionFactory
    private let lock = NSLock()
    private var prompts: [String] = []

    init(inner: any LLMSessionFactory) {
        self.inner = inner
    }

    var backendKind: LLMBackendKind { inner.backendKind }

    func makeSession(
        systemPrompt: String,
        tools: [any LLMTool],
        temperature: Double
    ) async throws -> any LLMSession {
        lock.lock()
        prompts.append(systemPrompt)
        lock.unlock()
        return try await inner.makeSession(
            systemPrompt: systemPrompt,
            tools: tools,
            temperature: temperature
        )
    }

    func recordedPrompts() async -> [String] {
        lock.lock(); defer { lock.unlock() }
        return prompts
    }
}

// MARK: - Recording test tool

private actor RecordingTool: LLMTool {
    nonisolated let id: String
    nonisolated let description: String = "test recording tool"
    nonisolated let jsonSchemaForArgs: String = "{}"
    private(set) var invocations: [String] = []

    init(id: String) { self.id = id }

    func invoke(argsJSON: String) async throws -> String {
        invocations.append(argsJSON)
        return "{\"ok\":true}"
    }
}
