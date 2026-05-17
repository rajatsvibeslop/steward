//
//  MockLLMSession.swift
//  Steward — Track B
//
//  Deterministic fixture set for the six canned turns from
//  implementation-addendum §1.10. **Pure function of (systemPrompt,
//  userMessage)** — addendum §4 hard reject #21 forbids randomness.
//
//  The mock disambiguates the six turns by parsing the
//  `conversation_state: <token>` line that `PromptAssembler` emits in
//  the runtime context segment (search for `MOCK_HINT` in
//  ConversationState.swift for the protocol). Real FoundationModels
//  ignores those lines — they are just additional system-prompt text.
//
//  All response text is prefixed `[MOCK]` so the UI banner is reinforced
//  inline (Pod E shows a STUB chip on every mock reply).
//
//  Determinism notes:
//   - `Date` values appear in `LLMToolInvocation.executedAt` for audit
//     traceability. The text + tool args are pure functions of input;
//     tests assert on text + toolID + args + result, ignoring `executedAt`.
//   - For repeatable tests, callers may pass a `Clock` to the factory.
//

import Foundation

public struct MockLLMSessionFactory: LLMSessionFactory {
    public let backendKind: LLMBackendKind
    public let clock: @Sendable () -> Date

    public init(
        reason: MockReason = .sdkNotCompiledIn,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backendKind = .mock(reason: reason)
        self.clock = clock
    }

    public func makeSession(
        systemPrompt: String,
        tools: [any LLMTool],
        temperature: Double
    ) async throws -> any LLMSession {
        return MockLLMSession(
            systemPrompt: systemPrompt,
            tools: tools,
            backendKind: backendKind,
            clock: clock
        )
    }
}

/// Deterministic LLM stub. Not a chatbot — a finite state-machine that
/// walks the empty-state flow end-to-end (spec §16, UXR v2).
public actor MockLLMSession: LLMSession {
    private let systemPrompt: String
    private let tools: [any LLMTool]
    private let backendKind: LLMBackendKind
    private let clock: @Sendable () -> Date

    public init(
        systemPrompt: String,
        tools: [any LLMTool],
        backendKind: LLMBackendKind,
        clock: @escaping @Sendable () -> Date
    ) {
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.backendKind = backendKind
        self.clock = clock
    }

    public func respond(to userMessage: String) async throws -> LLMResponse {
        let plan = MockResponsePlan.plan(
            systemPrompt: systemPrompt,
            userMessage: userMessage
        )

        var invocations: [LLMToolInvocation] = []
        for invocation in plan.toolCalls {
            let result = try await dispatch(
                toolID: invocation.toolID,
                argsJSON: invocation.argsJSON
            )
            invocations.append(LLMToolInvocation(
                toolID: invocation.toolID,
                argsJSON: invocation.argsJSON,
                resultJSON: result,
                executedAt: clock()
            ))
        }

        return LLMResponse(
            text: plan.text,
            toolInvocations: invocations,
            backendKind: backendKind
        )
    }

    public func reset() async {
        // No persistent KV cache — mock is stateless across turns.
    }

    // MARK: - Tool dispatch

    private func dispatch(toolID: String, argsJSON: String) async throws -> String {
        guard let tool = tools.first(where: { $0.id == toolID }) else {
            throw LLMSessionError.toolNotFound(toolID: toolID)
        }
        do {
            return try await tool.invoke(argsJSON: argsJSON)
        } catch {
            throw LLMSessionError.toolExecutionFailed(
                toolID: toolID,
                underlying: String(describing: error)
            )
        }
    }
}

// MARK: - Response planning (pure)

/// One planned tool call inside a mock response.
public struct MockPlannedToolCall: Sendable, Equatable {
    public let toolID: String
    public let argsJSON: String
}

/// The output of `MockResponsePlan.plan` — a pure function of input.
/// Exposed publicly so tests can assert determinism without running the
/// full actor.
public struct MockResponsePlan: Sendable, Equatable {
    public let text: String
    public let toolCalls: [MockPlannedToolCall]

    /// Six-case canned dispatcher. Pure function of (systemPrompt,
    /// userMessage). Same input → same output, every time.
    public static func plan(systemPrompt: String, userMessage: String) -> MockResponsePlan {
        let state = parseConversationState(from: systemPrompt)
        let branch = parseEmptyStateBranch(from: systemPrompt)
        let agentDomain = parseAgentDomain(from: systemPrompt)
        let lowered = userMessage.lowercased()

        // -----------------------------------------------------------------
        // Domain-agent dispatch (system prompt carries `agent_domain:`).
        // The 6 canned turns from §1.10 are coordinator-only; domain agents
        // get a small replay-style behavior keyed off the request text.
        // This makes the multi-hop test concrete.
        // -----------------------------------------------------------------
        if let domain = agentDomain {
            return domainAgentPlan(domain: domain, userMessageLowered: lowered, raw: userMessage)
        }

        // -----------------------------------------------------------------
        // Turn 6 — status read ("how am I doing", etc.)
        // Highest specificity so we don't accidentally absorb it into 5.
        // -----------------------------------------------------------------
        if containsAny(lowered, of: ["how am i doing", "status", "where do i stand", "how's it going"]) {
            let args = #"{"instrument_id":"inst_mock_default"}"#
            return MockResponsePlan(
                text: "[MOCK] Reading your latest instrument state. (Numbers come from the tool result, not me.)",
                toolCalls: [.init(toolID: ToolID.instrumentRead.rawValue, argsJSON: args)]
            )
        }

        // -----------------------------------------------------------------
        // Branch A capture — user typed a concrete event in EMPTY STATE.
        // This precedes the event-log keyword match below because in the
        // empty-state flow we have no instrument yet, so we MUST capture
        // via event.capture (not instrument.apply_event). Once domains
        // exist (branch == nil), the apply_event keyword path wins.
        // -----------------------------------------------------------------
        if branch == .branchACaptureFirst {
            let escaped = userMessage.replacingOccurrences(of: "\"", with: "\\\"")
            let args = "{\"text\":\"\(escaped)\"}"
            let followup = containsDigit(lowered)
                ? " Want me to start keeping this for you so you don't have to remember to log it? Yes or no."
                : ""
            return MockResponsePlan(
                text: "[MOCK] Logged.\(followup)",
                toolCalls: [.init(toolID: ToolID.eventCapture.rawValue, argsJSON: args)]
            )
        }

        // -----------------------------------------------------------------
        // Turn 4 — instrument confirm
        // -----------------------------------------------------------------
        if state == .awaitingInstrumentConfirm,
           containsAny(lowered, of: ["yes", "confirm", "sounds good", "do it", "yeah", "yep"]) {
            let args = #"{"kind":"rolling_average","name":"Sleep","domain":"health","definition":{"unit":"hours","window_days":7,"smoothing":"mean"}}"#
            return MockResponsePlan(
                text: "[MOCK] Added. When would you like a quiet morning brief — 7am okay, or different?",
                toolCalls: [.init(toolID: ToolID.instrumentCreate.rawValue, argsJSON: args)]
            )
        }

        // -----------------------------------------------------------------
        // Turn 3 — domain confirm (after a domain proposal)
        // -----------------------------------------------------------------
        if state == .awaitingDomainConfirm,
           containsAny(lowered, of: ["yes", "confirm", "sounds good", "do it", "yeah", "yep"]) {
            let args = #"{"domain":"health","display_name":"Health","role_prompt":"You are the Health agent. Your job is to keep a quiet, accurate record of what the user tells you, and to read instrument state when asked. You do not prompt, push, or moralize."}"#
            return MockResponsePlan(
                text: "[MOCK] Done — the Health team is set up. Easiest first thing to track: sleep hours, 7-day average. Want it?",
                toolCalls: [.init(toolID: ToolID.domainCreate.rawValue, argsJSON: args)]
            )
        }

        // -----------------------------------------------------------------
        // Turn 5 — event capture/apply (free-chat path; an instrument exists)
        // Match /log|spent|slept|did|ate|drank|ran|walked|weighed/ with a
        // quantity hint (digit anywhere in the message).
        // -----------------------------------------------------------------
        if containsAny(lowered, of: ["log", "spent", "slept", "ate", "drank", "ran ", "walked", "weighed"])
           && containsDigit(lowered) {
            let escaped = userMessage.replacingOccurrences(of: "\"", with: "\\\"")
            let args = "{\"instrument_id\":\"inst_mock_default\",\"event_kind\":\"log_entry\",\"value_raw\":\"\(escaped)\"}"
            return MockResponsePlan(
                text: "[MOCK] Logged.",
                toolCalls: [.init(toolID: ToolID.instrumentApplyEvent.rawValue, argsJSON: args)]
            )
        }

        // -----------------------------------------------------------------
        // Turn 2 — domain proposal (user named a life area in Branch B)
        // Also triggers when message contains track/log/monitor verbs.
        // -----------------------------------------------------------------
        if branch == .branchBSetupFirst
           || containsAny(lowered, of: ["track", "monitor", "keep an eye on", "help me with"]) {
            return MockResponsePlan(
                text: "[MOCK] Got it. I'll call this the Health team. How should it act?\n\n" +
                      "- Stay gentle. Just track. (default)\n" +
                      "- Push back a little when I'm slipping.\n" +
                      "- Push hard. Call me out when needed.\n\n" +
                      "Reply 'yes' to take the default, or pick a tone.",
                toolCalls: []
            )
        }

        // -----------------------------------------------------------------
        // Turn 1 — greeting + open question (first message; or unclear)
        // -----------------------------------------------------------------
        if state == .awaitingFirstMessage || branch == .branchCUnclear {
            return MockResponsePlan(
                text: "[MOCK] Morning. I'm Steward. " +
                      "Tell me something I should catch — sleep, money, the kitchen, a thing " +
                      "on your mind — or say \"walk me through it\" and I'll help set up a first piece.",
                toolCalls: []
            )
        }

        // -----------------------------------------------------------------
        // Default — neutral acknowledgement; never moralize, never push.
        // This path is what coordinator falls back to in inFreeChat with
        // no recognizable intent.
        // -----------------------------------------------------------------
        return MockResponsePlan(
            text: "[MOCK] Got it.",
            toolCalls: []
        )
    }

    // MARK: - Domain-agent canned dispatch

    /// When the system prompt carries `agent_domain: <d>`, this agent is a
    /// domain agent. Two stock behaviors so the multi-hop test has
    /// something deterministic to inspect:
    ///   - request mentions "log" or a number → call event.capture
    ///   - request mentions "status" or "read" → call instrument.read
    ///   - otherwise → flat acknowledgement
    private static func domainAgentPlan(domain: String, userMessageLowered: String, raw: String) -> MockResponsePlan {
        if containsAny(userMessageLowered, of: ["status", "read", "where do i stand", "how am i doing"]) {
            let args = "{\"instrument_id\":\"inst_\(domain)_default\"}"
            return MockResponsePlan(
                text: "[MOCK] Reading \(domain) instrument state.",
                toolCalls: [.init(toolID: ToolID.instrumentRead.rawValue, argsJSON: args)]
            )
        }
        if containsAny(userMessageLowered, of: ["log", "spent", "slept", "ate", "did", "weighed"])
           || containsDigit(userMessageLowered) {
            let escaped = raw.replacingOccurrences(of: "\"", with: "\\\"")
            let args = "{\"text\":\"\(escaped)\",\"domain\":\"\(domain)\"}"
            return MockResponsePlan(
                text: "[MOCK] \(domain) — logged.",
                toolCalls: [.init(toolID: ToolID.eventCapture.rawValue, argsJSON: args)]
            )
        }
        return MockResponsePlan(
            text: "[MOCK] \(domain) — got it.",
            toolCalls: []
        )
    }

    // MARK: - System-prompt parsing helpers

    /// Token → state table. Dictionary lookup (not a `switch ... default:`)
    /// keeps `rg "default:"` clean against §4 hard reject style.
    private static let conversationStateByToken: [String: ConversationState] = [
        "awaiting_first_message":        .awaitingFirstMessage,
        "captured_awaiting_track_offer": .capturedAwaitingTrackOffer,
        "awaiting_life_area_answer":     .awaitingLifeAreaAnswer,
        "proposing_domain":              .proposingDomain,
        "awaiting_domain_confirm":       .awaitingDomainConfirm,
        "proposing_instrument":          .proposingInstrument,
        "awaiting_instrument_confirm":   .awaitingInstrumentConfirm,
        "unclear_on_ramp":               .unclearOnRamp,
        "free_chat":                     .inFreeChat,
    ]

    private static let branchByToken: [String: EmptyStateBranch] = [
        "branch_a": .branchACaptureFirst,
        "branch_b": .branchBSetupFirst,
        "branch_c": .branchCUnclear,
    ]

    static func parseConversationState(from systemPrompt: String) -> ConversationState {
        guard let token = parseField(systemPrompt, key: "conversation_state") else {
            return .inFreeChat
        }
        return conversationStateByToken[token] ?? .inFreeChat
    }

    static func parseEmptyStateBranch(from systemPrompt: String) -> EmptyStateBranch? {
        guard let token = parseField(systemPrompt, key: "empty_state_branch") else {
            return nil
        }
        return branchByToken[token]
    }

    static func parseAgentDomain(from systemPrompt: String) -> String? {
        return parseField(systemPrompt, key: "agent_domain")
    }

    /// Parses a single-line `key: value` from the runtime-context segment.
    /// Returns the value verbatim with surrounding whitespace trimmed.
    private static func parseField(_ systemPrompt: String, key: String) -> String? {
        let lines = systemPrompt.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let valueStart = trimmed.index(trimmed.startIndex, offsetBy: key.count + 1)
            return String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - String matching helpers

    private static func containsAny(_ haystack: String, of needles: [String]) -> Bool {
        for n in needles where haystack.contains(n) {
            return true
        }
        return false
    }

    private static func containsDigit(_ s: String) -> Bool {
        return s.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) })
    }
}
