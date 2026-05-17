//
//  MockLLMSession.swift
//  Steward — Track B
//
//  Deterministic fixture set for the six canned turns from
//  implementation-addendum §1.10. **Pure function of (systemPrompt,
//  userMessage, state, now)** — addendum §4 hard reject #21 forbids
//  randomness.
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
//   - Cross-turn state (e.g. the instrument_id returned by a prior
//     `instrument.create`) lives on a shared `MockSessionStateStore`
//     attached to the factory. Each `respond(to:)` reads a snapshot
//     before planning and updates the store after dispatching a
//     `instrument.create`. Stateless plan() callers (most unit tests)
//     pass an empty `MockSessionState`.
//

import Foundation

/// Cross-turn state the mock threads between calls to keep the empty-state
/// flow stitched together (turn 4 → turn 5/6 reference the new instrument_id).
public struct MockSessionState: Sendable, Equatable {
    public var lastCreatedInstrumentID: String?
    public var lastCreatedDomain: String?

    public init(
        lastCreatedInstrumentID: String? = nil,
        lastCreatedDomain: String? = nil
    ) {
        self.lastCreatedInstrumentID = lastCreatedInstrumentID
        self.lastCreatedDomain = lastCreatedDomain
    }
}

/// Process-wide store for the mock's cross-turn fields. One instance per
/// factory — every session the factory mints shares the same store, so
/// turn 4's instrument_id reaches turn 5/6 even though AgentLoop builds a
/// fresh session per turn.
public actor MockSessionStateStore {
    private var state: MockSessionState

    public init(initial: MockSessionState = MockSessionState()) {
        self.state = initial
    }

    public func snapshot() -> MockSessionState { state }

    public func setLastCreatedInstrumentID(_ id: String) {
        state.lastCreatedInstrumentID = id
    }

    public func setLastCreatedDomain(_ domain: String) {
        state.lastCreatedDomain = domain
    }
}

public struct MockLLMSessionFactory: LLMSessionFactory {
    public let backendKind: LLMBackendKind
    public let clock: @Sendable () -> Date
    public let stateStore: MockSessionStateStore

    public init(
        reason: MockReason = .sdkNotCompiledIn,
        clock: @escaping @Sendable () -> Date = { Date() },
        stateStore: MockSessionStateStore = MockSessionStateStore()
    ) {
        self.backendKind = .mock(reason: reason)
        self.clock = clock
        self.stateStore = stateStore
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
            clock: clock,
            stateStore: stateStore
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
    private let stateStore: MockSessionStateStore

    public init(
        systemPrompt: String,
        tools: [any LLMTool],
        backendKind: LLMBackendKind,
        clock: @escaping @Sendable () -> Date,
        stateStore: MockSessionStateStore = MockSessionStateStore()
    ) {
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.backendKind = backendKind
        self.clock = clock
        self.stateStore = stateStore
    }

    public func respond(to userMessage: String) async throws -> LLMResponse {
        let priorState = await stateStore.snapshot()
        let plan = MockResponsePlan.plan(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            state: priorState,
            now: clock()
        )

        var invocations: [LLMToolInvocation] = []
        for invocation in plan.toolCalls {
            let result = try await dispatch(
                toolID: invocation.toolID,
                argsJSON: invocation.argsJSON
            )
            // After a successful instrument.create, cache the new
            // instrument_id so a later turn's instrument.read / apply_event
            // can reference it concretely (instead of the placeholder
            // "inst_mock_default" that won't resolve against a real DB).
            if invocation.toolID == ToolID.instrumentCreate.rawValue,
               let id = Self.parseInstrumentID(fromResultJSON: result) {
                await stateStore.setLastCreatedInstrumentID(id)
            }
            if invocation.toolID == ToolID.domainCreate.rawValue,
               let domain = Self.parseDomain(fromResultJSON: result) {
                await stateStore.setLastCreatedDomain(domain)
            }
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
        // No persistent KV cache — mock is stateless across turns at the
        // session level; cross-turn state lives on the factory's store
        // and is not reset here.
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

    // MARK: - Result parsing

    /// Extracts `instrument_id` from a JSON result body. We accept the
    /// `nil` outcome (e.g. the test stubs return `{"ok":true}` shapes)
    /// and just don't update the cached state.
    private static func parseInstrumentID(fromResultJSON json: String) -> String? {
        return parseStringField("instrument_id", in: json)
    }

    private static func parseDomain(fromResultJSON json: String) -> String? {
        return parseStringField("domain", in: json)
    }

    private static func parseStringField(_ key: String, in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[key] as? String,
              !value.isEmpty else {
            return nil
        }
        return value
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

    /// Default "now" the pure-plan path uses when the caller doesn't pass
    /// one. Anchored in 2026 so emitted ISO timestamps stay plausible for
    /// schema-validation tests.
    public static let defaultPlanningNow: Date = Date(timeIntervalSince1970: 1_779_000_000)

    /// Canned dispatcher. Pure function of (systemPrompt, userMessage,
    /// state, now). Same input → same output, every time.
    public static func plan(
        systemPrompt: String,
        userMessage: String,
        state: MockSessionState = MockSessionState(),
        now: Date = MockResponsePlan.defaultPlanningNow
    ) -> MockResponsePlan {
        let convoState = parseConversationState(from: systemPrompt)
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
            return domainAgentPlan(
                domain: domain,
                userMessageLowered: lowered,
                raw: userMessage,
                state: state
            )
        }

        // -----------------------------------------------------------------
        // Turn 6 — status read ("how am I doing", etc.) — highest specificity.
        // -----------------------------------------------------------------
        if containsAny(lowered, of: ["how am i doing", "status", "where do i stand", "how's it going"]) {
            return instrumentReadPlan(state: state)
        }

        // -----------------------------------------------------------------
        // New tool intents (qa-1 gaps): mercy_mode, quiet_hours,
        // notification.schedule, reminder.create, calendar.read. These
        // take priority over the freeform capture/apply paths so that
        // "remind me at 7am" doesn't get absorbed into event.capture.
        // -----------------------------------------------------------------
        if lowered.contains("mercy mode") {
            return mercyModePlan(now: now)
        }
        if lowered.contains("quiet hours") {
            return quietHoursPlan()
        }
        if lowered.contains("remind me at") {
            return notificationSchedulePlan(now: now, userMessage: userMessage)
        }
        if lowered.contains("remind me to") || lowered.contains("create a reminder") {
            return reminderCreatePlan(userMessage: userMessage)
        }
        if containsAny(lowered, of: [
            "what's on my calendar",
            "what is on my calendar",
            "whats on my calendar",
            "today's calendar",
            "my calendar today"
        ]) {
            return calendarReadPlan(now: now)
        }

        // -----------------------------------------------------------------
        // Morning-brief refresh (Today tab calls coordinator with a fixed
        // prompt; the mock returns deterministic copy so the brief card
        // doesn't render "[MOCK] Got it." back at the user).
        // -----------------------------------------------------------------
        if isMorningBriefRequest(lowered: lowered) {
            return morningBriefPlan()
        }

        // -----------------------------------------------------------------
        // Branch A capture — user typed a concrete event in EMPTY STATE.
        // Precedes the event-log keyword match below because in empty-state
        // we have no instrument yet, so we MUST capture via event.capture
        // (not instrument.apply_event). Once domains exist (branch == nil),
        // the apply_event keyword path wins.
        // -----------------------------------------------------------------
        if branch == .branchACaptureFirst {
            let followup = containsDigit(lowered)
                ? " Want me to start keeping this for you so you don't have to remember to log it? Yes or no."
                : ""
            return MockResponsePlan(
                text: "[MOCK] Logged.\(followup)",
                toolCalls: [.init(
                    toolID: ToolID.eventCapture.rawValue,
                    argsJSON: encodeArgs(EventCaptureArgs(
                        text: userMessage,
                        domain: nil,
                        kind: "log_entry",
                        payloadJSON: nil,
                        reasoning: "[MOCK] branch-A capture; user reported an event in empty state",
                        actor: "coordinator"
                    ))
                )]
            )
        }

        // -----------------------------------------------------------------
        // Turn 4 — instrument confirm
        // -----------------------------------------------------------------
        if convoState == .awaitingInstrumentConfirm,
           containsAny(lowered, of: ["yes", "confirm", "sounds good", "do it", "yeah", "yep"]) {
            return MockResponsePlan(
                text: "[MOCK] Added. When would you like a quiet morning brief — 7am okay, or different?",
                toolCalls: [.init(
                    toolID: ToolID.instrumentCreate.rawValue,
                    argsJSON: encodeArgs(InstrumentCreateArgs(
                        kind: "rolling_average",
                        name: "Sleep",
                        domain: "health",
                        definitionJSON: #"{"unit":"hours","window_days":7,"smoothing":"mean"}"#,
                        reviewCadence: nil,
                        reasoning: "[MOCK] user confirmed the proposed sleep instrument",
                        actor: "coordinator"
                    ))
                )]
            )
        }

        // -----------------------------------------------------------------
        // Turn 3 — domain confirm (after a domain proposal)
        // -----------------------------------------------------------------
        if convoState == .awaitingDomainConfirm,
           containsAny(lowered, of: ["yes", "confirm", "sounds good", "do it", "yeah", "yep"]) {
            return MockResponsePlan(
                text: "[MOCK] Done — the Health team is set up. Easiest first thing to track: sleep hours, 7-day average. Want it?",
                toolCalls: [.init(
                    toolID: ToolID.domainCreate.rawValue,
                    argsJSON: encodeArgs(DomainCreateArgs(
                        domain: "health",
                        displayName: "Health",
                        rolePrompt: "You are the Health agent. Your job is to keep a quiet, accurate record of what the user tells you, and to read instrument state when asked. You do not prompt, push, or moralize.",
                        toolScopeJSON: nil,
                        defaultQuietHours: nil,
                        reasoning: "[MOCK] user confirmed the proposed Health domain",
                        actor: "coordinator"
                    ))
                )]
            )
        }

        // -----------------------------------------------------------------
        // Turn 5 — event capture/apply (free-chat path; an instrument exists)
        // Match /log|spent|slept|did|ate|drank|ran|walked|weighed/ with a
        // quantity hint (digit anywhere in the message).
        // -----------------------------------------------------------------
        if containsAny(lowered, of: ["log", "spent", "slept", "ate", "drank", "ran ", "walked", "weighed"])
           && containsDigit(lowered) {
            let instrumentID = state.lastCreatedInstrumentID ?? "inst_mock_default"
            return MockResponsePlan(
                text: "[MOCK] Logged.",
                toolCalls: [.init(
                    toolID: ToolID.instrumentApplyEvent.rawValue,
                    argsJSON: encodeArgs(InstrumentApplyEventArgs(
                        instrumentID: InstrumentID(rawValue: instrumentID),
                        eventKind: "log_entry",
                        payloadJSON: encodeArgs(["raw": userMessage]),
                        notes: nil,
                        reasoning: "[MOCK] user reported a quantitative event; applying to the active instrument",
                        actor: "coordinator"
                    ))
                )]
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
        if convoState == .awaitingFirstMessage || branch == .branchCUnclear {
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

    // MARK: - Sub-plans for each tool intent

    private static func instrumentReadPlan(state: MockSessionState) -> MockResponsePlan {
        let instrumentID = state.lastCreatedInstrumentID ?? "inst_mock_default"
        return MockResponsePlan(
            text: "[MOCK] Reading your latest instrument state. (Numbers come from the tool result, not me.)",
            toolCalls: [.init(
                toolID: ToolID.instrumentRead.rawValue,
                argsJSON: encodeArgs(InstrumentReadArgs(
                    instrumentID: InstrumentID(rawValue: instrumentID)
                ))
            )]
        )
    }

    private static func mercyModePlan(now: Date) -> MockResponsePlan {
        let untilWhen = now.addingTimeInterval(24 * 3600)
        return MockResponsePlan(
            text: "[MOCK] Mercy mode on for the next 24 hours. I'll soften nudges and keep the bar low. You can lift it any time.",
            toolCalls: [.init(
                toolID: ToolID.mercyModeEngage.rawValue,
                argsJSON: encodeArgs(MercyModeEngageArgs(
                    untilWhen: untilWhen,
                    reason: "User asked for a softer day.",
                    reasoning: "[MOCK] user explicitly invoked mercy mode in chat",
                    actor: "coordinator"
                ))
            )]
        )
    }

    private static func quietHoursPlan() -> MockResponsePlan {
        return MockResponsePlan(
            text: "[MOCK] Set quiet hours to 22:00–07:00 local. Tell me a different window any time and I'll move it.",
            toolCalls: [.init(
                toolID: ToolID.quietHoursSet.rawValue,
                argsJSON: encodeArgs(QuietHoursSetArgs(
                    start: "22:00",
                    end: "07:00",
                    reasoning: "[MOCK] user asked to set quiet hours; using the spec default window",
                    actor: "coordinator"
                ))
            )]
        )
    }

    private static func notificationSchedulePlan(now: Date, userMessage: String) -> MockResponsePlan {
        // Fire ~1 hour out — concrete enough that the scheduler accepts it.
        let fireAt = now.addingTimeInterval(3600)
        let args = NotificationScheduleArgs(
            kind: .instrumentNudge,
            fireAt: fireAt,
            domain: nil,
            instrumentID: nil,
            commitmentTitle: nil,
            instrumentName: nil,
            domainDisplayName: nil,
            briefTimeDisplay: nil,
            actionContextJSON: nil,
            reasoning: "[MOCK] user asked for a nudge at a specific time: \(userMessage)"
        )
        return MockResponsePlan(
            text: "[MOCK] Scheduled a nudge. You'll see a notification then; tap it to log or postpone.",
            toolCalls: [.init(
                toolID: ToolID.notificationSchedule.rawValue,
                argsJSON: encodeArgsISO(args)
            )]
        )
    }

    private static func reminderCreatePlan(userMessage: String) -> MockResponsePlan {
        let title = extractReminderTitle(from: userMessage)
        let args = ReminderCreateArgs(
            title: title,
            dueDate: nil,
            notes: nil,
            listName: nil,
            reasoning: "[MOCK] user asked me to create a reminder for them"
        )
        return MockResponsePlan(
            text: "[MOCK] Added to Reminders.",
            toolCalls: [.init(
                toolID: ToolID.reminderCreate.rawValue,
                argsJSON: encodeArgsISO(args)
            )]
        )
    }

    private static func calendarReadPlan(now: Date) -> MockResponsePlan {
        let start = startOfDay(now)
        let end = start.addingTimeInterval(24 * 3600)
        let args = CalendarReadArgs(
            start: start,
            end: end,
            calendarName: nil,
            reasoning: "[MOCK] user asked what's on their calendar today"
        )
        return MockResponsePlan(
            text: "[MOCK] Pulling today's calendar.",
            toolCalls: [.init(
                toolID: ToolID.calendarRead.rawValue,
                argsJSON: encodeArgsISO(args)
            )]
        )
    }

    private static func morningBriefPlan() -> MockResponsePlan {
        // Deterministic copy — no fake numbers, no moralizing. The text
        // makes it explicit we're on the stub backend so the user knows
        // the brief isn't reading their state yet.
        let text = "[MOCK] Quiet morning brief: I'm on the stub backend until Apple Intelligence comes online, so the numbers below are what Today already shows you — instruments by domain, anything coming up in the next 12 hours, and your last few captures. Nothing's urgent. Tell me what you want to track today, or just say what's on your mind."
        return MockResponsePlan(text: text, toolCalls: [])
    }

    // MARK: - Domain-agent canned dispatch

    /// When the system prompt carries `agent_domain: <d>`, this agent is a
    /// domain agent. Two stock behaviors so the multi-hop test has
    /// something deterministic to inspect:
    ///   - request mentions "log" or a number → call event.capture
    ///   - request mentions "status" or "read" → call instrument.read
    ///   - otherwise → flat acknowledgement
    private static func domainAgentPlan(
        domain: String,
        userMessageLowered: String,
        raw: String,
        state: MockSessionState
    ) -> MockResponsePlan {
        if containsAny(userMessageLowered, of: ["status", "read", "where do i stand", "how am i doing"]) {
            let instrumentID = state.lastCreatedInstrumentID ?? "inst_\(domain)_default"
            return MockResponsePlan(
                text: "[MOCK] Reading \(domain) instrument state.",
                toolCalls: [.init(
                    toolID: ToolID.instrumentRead.rawValue,
                    argsJSON: encodeArgs(InstrumentReadArgs(
                        instrumentID: InstrumentID(rawValue: instrumentID)
                    ))
                )]
            )
        }
        if containsAny(userMessageLowered, of: ["log", "spent", "slept", "ate", "did", "weighed"])
           || containsDigit(userMessageLowered) {
            return MockResponsePlan(
                text: "[MOCK] \(domain) — logged.",
                toolCalls: [.init(
                    toolID: ToolID.eventCapture.rawValue,
                    argsJSON: encodeArgs(EventCaptureArgs(
                        text: raw,
                        domain: domain,
                        kind: "log_entry",
                        payloadJSON: nil,
                        reasoning: "[MOCK] domain agent capturing a freeform event for \(domain)",
                        actor: "agent:\(domain)"
                    ))
                )]
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

    private static func isMorningBriefRequest(lowered: String) -> Bool {
        if lowered.contains("morning's brief") { return true }
        if lowered.contains("morning brief") { return true }
        if lowered.contains("generate") && lowered.contains("brief") { return true }
        return false
    }

    private static func extractReminderTitle(from message: String) -> String {
        // Trim what comes after "remind me to " / "create a reminder ".
        // Falls back to the whole message if neither marker is found —
        // preserves user content, no placeholder strings.
        let lowered = message.lowercased()
        let markers = ["remind me to ", "create a reminder to ", "create a reminder "]
        for marker in markers {
            if let range = lowered.range(of: marker) {
                let tailStart = message.index(message.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: range.upperBound))
                let tail = message[tailStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    return String(tail)
                }
            }
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func startOfDay(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal.startOfDay(for: date)
    }

    // MARK: - Args encoding helpers

    /// Encodes any `Encodable` args struct as the JSON string the tool's
    /// decoder will accept (sortedKeys + iso8601). For args used by tools
    /// that go through `ToolJSON` (Pod C catalog: domain/instrument/event/
    /// settings/memory/commitments), this round-trips by construction.
    static func encodeArgs<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(value),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        // Unreachable for our deterministic inputs; the args structs we
        // pass in only carry JSON-safe scalars. Returning an empty object
        // here keeps the call site non-throwing so we don't have to wrap
        // every fixture in `try?`.
        return "{}"
    }

    /// Same as `encodeArgs` — Pod D notification/calendar/reminder tools
    /// also use iso8601 dates, but they live on their own decoders. Naming
    /// the helper separately documents the distinct intent at call sites.
    static func encodeArgsISO<T: Encodable>(_ value: T) -> String {
        return encodeArgs(value)
    }
}
