//
//  AgentLoop.swift
//  Steward — Track B
//
//  One actor owns one user-session's turn loop. Per addendum §1.1 + §1.10:
//
//   - Foundation Models auto-loops internal tool calls. We never manually
//     loop them (§4 hard reject #7). The coordinator's session calls
//     `respond(to:)` once per user message and the framework runs as many
//     tool calls as the model wants before returning.
//
//   - The ONE exception is `agent.handoff`. It's hand-rolled as an
//     `LLMTool` whose `invoke()` consumes a `TurnBudget` hop, spawns a
//     domain agent's session, and returns the domain reply to the
//     coordinator's session as the tool result. The framework then
//     continues the coordinator's reply with that result available. This
//     is what makes the 8-hop cap mean "max 8 cross-agent handoffs per
//     coordinator turn".
//
//   - The empty-state branch is decided deterministically BEFORE the LLM
//     call (`EmptyStateRouter`). `ConversationState` is threaded across
//     turns by this actor; the assembler emits it into the runtime context
//     segment so `MockLLMSession` can disambiguate canned turns.
//

import Foundation

// MARK: - Shared budget

/// Wraps the mutable `TurnBudget` so the agent.handoff tool (which runs
/// inside the LLM's tool-call auto-loop) and the AgentLoop (which spawns
/// it) can share a single counter without races.
public actor SharedBudget {
    public private(set) var budget: TurnBudget

    public init(budget: TurnBudget) {
        self.budget = budget
    }

    public func consumeHandoff() throws {
        try budget.consumeHandoff()
    }

    public func snapshot() -> TurnBudget { budget }
    public var handoffsRemaining: Int { budget.handoffsRemaining }
    public var handoffsConsumed: Int {
        TurnBudget.defaultHandoffs - budget.handoffsRemaining
    }
}

// MARK: - Domain resolution

/// Looks up an active `DomainAgent` by domain identifier. Track C / Pod E
/// own the canonical `domains` table reader; for v0.9 the AgentLoop ships
/// with a closure-based resolver so tests can inject fixtures and the real
/// app wires in a DB-backed implementation.
public protocol DomainAgentResolver: Sendable {
    func resolve(domain: String) async -> DomainAgent?
    func listActive() async -> [DomainSummary]
}

public struct FixtureDomainAgentResolver: DomainAgentResolver {
    private let byID: [String: DomainAgent]
    public init(domains: [DomainAgent]) {
        self.byID = Dictionary(
            uniqueKeysWithValues: domains.map { ($0.domain, $0) }
        )
    }
    public func resolve(domain: String) async -> DomainAgent? { byID[domain] }
    public func listActive() async -> [DomainSummary] {
        byID.values.map { DomainSummary(domain: $0.domain, displayName: $0.displayName) }
    }
}

// MARK: - Agent loop

public actor AgentLoop {
    private let factory: any LLMSessionFactory
    private let registry: any ToolRegistry
    private let coordinator: CoordinatorAgent
    private let resolver: any DomainAgentResolver
    private let temperature: Double
    private let clock: @Sendable () -> Date
    private let timezone: TimeZone
    private let turnIDGen: @Sendable () -> String

    /// Conversation state threaded across turns. Tests can seed it via the
    /// `initialState` init arg.
    private var conversationState: ConversationState

    public init(
        factory: any LLMSessionFactory,
        registry: any ToolRegistry,
        coordinator: CoordinatorAgent = CoordinatorAgent(),
        resolver: any DomainAgentResolver,
        temperature: Double = 0.7,
        clock: @escaping @Sendable () -> Date = { Date() },
        timezone: TimeZone = .autoupdatingCurrent,
        turnIDGen: @escaping @Sendable () -> String = { UUID().uuidString },
        initialState: ConversationState = .awaitingFirstMessage
    ) {
        self.factory = factory
        self.registry = registry
        self.coordinator = coordinator
        self.resolver = resolver
        self.temperature = temperature
        self.clock = clock
        self.timezone = timezone
        self.turnIDGen = turnIDGen
        self.conversationState = initialState
    }

    /// Run one user turn through the coordinator. Throws on session-level
    /// failures; returns a typed `CoordinatorResponse` for all in-band
    /// outcomes (including handoff-budget exhaustion).
    public func run(userMessage: String) async throws -> CoordinatorResponse {
        let turnID = TurnID(raw: turnIDGen())
        let now = clock()
        let activeDomains = await resolver.listActive()

        // Pre-LLM deterministic routing — only relevant when no domains
        // exist yet (empty state). Once at least one domain exists, the
        // coordinator drops the scripted flow per UXR v2 §4.7.
        let branch: EmptyStateBranch?
        if activeDomains.isEmpty {
            branch = EmptyStateRouter.route(userMessage)
        } else {
            branch = nil
        }

        // Compute the new conversation state for THIS turn based on the
        // prior state + branch + user message shape.
        conversationState = nextConversationState(
            prior: conversationState,
            branch: branch,
            userMessage: userMessage,
            activeDomainsEmpty: activeDomains.isEmpty
        )

        let runtime = RuntimeContext(
            now: now,
            localTimezone: timezone,
            conversationState: conversationState,
            emptyStateBranch: branch,
            mercyMode: .off,         // Pod D wires the real read from SettingsStore
            pauseUntil: nil,
            activeDomains: activeDomains,
            openCommitments: [],
            recentEventsSummary: nil,
            memoryHitsSummary: nil,
            todayCalendarSummary: nil,
            userMessage: userMessage,
            priorTurnSummary: nil
        )

        let prompt = coordinator.systemPrompt(runtime: runtime)

        // Build the tool list given to the coordinator's LLM session:
        // every registered tool whose ID is in coordinator scope, PLUS
        // the hand-rolled agent.handoff wrapper.
        let sharedBudget = SharedBudget(
            budget: TurnBudget(
                handoffsRemaining: TurnBudget.defaultHandoffs,
                contextTokenCeiling: TurnBudget.coordinatorTokenCeiling,
                startedAt: now
            )
        )
        var coordinatorTools = await registry.tools(in: coordinator.scope.allowedTools)
        coordinatorTools.append(AgentHandoffTool(
            budget: sharedBudget,
            resolver: resolver,
            registry: registry,
            factory: factory,
            temperature: temperature,
            timezone: timezone,
            clock: clock
        ))

        let session = try await factory.makeSession(
            systemPrompt: prompt.text,
            tools: coordinatorTools,
            temperature: temperature
        )
        let response = try await session.respond(to: userMessage)

        let consumed = await sharedBudget.handoffsConsumed
        let exhausted = await sharedBudget.handoffsRemaining == 0
            && response.toolInvocations.contains(where: { $0.toolID == ToolID.agentHandoff.rawValue })

        return CoordinatorResponse(
            turnID: turnID,
            text: response.text,
            backendKind: response.backendKind,
            toolInvocations: response.toolInvocations,
            handoffsConsumed: consumed,
            budgetExhausted: exhausted
        )
    }

    // MARK: - State transitions

    /// Pure-function state transition. Exposed to tests via the `internal`
    /// import on the test target; the production path always goes through
    /// `run(userMessage:)`.
    ///
    /// Per team-lead deslop S1 follow-ups:
    ///   - `.awaitingLifeAreaAnswer → .awaitingDomainConfirm` now requires
    ///     the user to have answered substantively (not refused).
    ///   - `.capturedAwaitingTrackOffer where isYes → .awaitingInstrumentConfirm`
    ///     per UXR §3.3 reading (the team is proposed and confirmed in
    ///     sequence — instrument creation is a logical follow-on step).
    func nextConversationState(
        prior: ConversationState,
        branch: EmptyStateBranch?,
        userMessage: String,
        activeDomainsEmpty: Bool
    ) -> ConversationState {
        guard activeDomainsEmpty else {
            return .inFreeChat
        }
        // Honor explicit branch transitions first.
        if let branch {
            switch branch {
            case .branchACaptureFirst:
                return .capturedAwaitingTrackOffer
            case .branchBSetupFirst:
                return .awaitingLifeAreaAnswer
            case .branchCUnclear:
                return .unclearOnRamp
            }
        }

        let yesNo = Self.classifyAffirmation(userMessage)
        switch prior {
        case .awaitingLifeAreaAnswer:
            // The user just named a life area. Only advance to the domain-
            // confirm step if they didn't refuse — explicit "no" / "skip"
            // bounces back to free chat per UXR §4 spirit (the user can
            // pull out anytime).
            return yesNo.isRefusal ? .inFreeChat : .awaitingDomainConfirm
        case .awaitingDomainConfirm where yesNo.isAffirmative:
            return .awaitingInstrumentConfirm
        case .awaitingInstrumentConfirm where yesNo.isAffirmative:
            return .inFreeChat
        case .capturedAwaitingTrackOffer where yesNo.isAffirmative:
            return .awaitingInstrumentConfirm
        case .capturedAwaitingTrackOffer where yesNo.isRefusal:
            return .inFreeChat
        case .capturedAwaitingTrackOffer,
             .awaitingDomainConfirm,
             .awaitingInstrumentConfirm,
             .unclearOnRamp,
             .awaitingFirstMessage,
             .proposingDomain,
             .proposingInstrument,
             .inFreeChat:
            return prior
        }
    }

    /// Trinary classification of user-confirmation messages.
    ///
    /// Per deslop S2: substring matching is too aggressive ("no okay" →
    /// matches "ok"; "yeah no" → matches "yeah"). Tokenize on whitespace
    /// (NOT on apostrophes — we want "don't" / "let's" intact), strip
    /// surrounding punctuation from each token, then look at leading
    /// 1/2/3-token windows, plus a guard against any negation token.
    static func classifyAffirmation(_ raw: String) -> AffirmationClassification {
        let tokens = raw
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }

        guard let leading = tokens.first else {
            return .unclear
        }

        let refusalSet: Set<String> = ["no", "nope", "nah", "skip", "don't", "dont", "stop", "never"]
        let affirmativeLead: Set<String> = ["yes", "yeah", "yep", "yup", "confirm", "ok", "okay", "sure", "absolutely"]

        // Negation anywhere in the message poisons affirmation.
        let hasRefusalToken = tokens.contains(where: { refusalSet.contains($0) })
        if hasRefusalToken {
            return .refusal
        }

        if affirmativeLead.contains(leading) {
            return .affirmative
        }

        // Multi-word affirmatives. Check leading 2-token and 3-token
        // windows ("sounds good", "do it", "go for it", "let's do it").
        let firstTwo = tokens.prefix(2).joined(separator: " ")
        let firstThree = tokens.prefix(3).joined(separator: " ")
        let multiWordAffirmatives: Set<String> = [
            "sounds good", "do it", "go for it",
            "let's do it", "lets do it",
        ]
        if multiWordAffirmatives.contains(firstTwo)
            || multiWordAffirmatives.contains(firstThree)
        {
            return .affirmative
        }

        return .unclear
    }

    enum AffirmationClassification: Equatable {
        case affirmative
        case refusal
        case unclear

        var isAffirmative: Bool { self == .affirmative }
        var isRefusal: Bool { self == .refusal }
    }

    /// Tests + Track E's chat-replay path read the current state to render
    /// the right input prompt / chip set.
    public func currentConversationState() -> ConversationState {
        return conversationState
    }
}

// MARK: - agent.handoff tool

/// The only hand-rolled tool. Consumes one `TurnBudget` hop, spawns a
/// domain agent session, returns the domain reply to the coordinator
/// session as JSON. Foundation Models then auto-continues with that
/// reply available.
public struct AgentHandoffTool: LLMTool {
    public let id: String = ToolID.agentHandoff.rawValue
    public let description: String = "Hand off to a domain agent. Counts one budget hop per call. Args: {domain: string, message: string}."
    public let jsonSchemaForArgs: String = """
        {
          "type": "object",
          "properties": {
            "domain": {"type": "string"},
            "message": {"type": "string"}
          },
          "required": ["domain", "message"]
        }
        """

    let budget: SharedBudget
    let resolver: any DomainAgentResolver
    let registry: any ToolRegistry
    let factory: any LLMSessionFactory
    let temperature: Double
    let timezone: TimeZone
    let clock: @Sendable () -> Date

    public func invoke(argsJSON: String) async throws -> String {
        // Parse args defensively — malformed JSON → structured error
        // back to the LLM (never throw fatal).
        let args: HandoffArgs
        do {
            let data = Data(argsJSON.utf8)
            args = try JSONDecoder().decode(HandoffArgs.self, from: data)
        } catch {
            return errorJSON(
                kind: "malformed_args",
                detail: String(describing: error)
            )
        }

        // Consume budget; on exhaustion, return structured error JSON.
        // The coordinator's LLM continues with that result available and
        // produces a final text without retrying handoff.
        do {
            try await budget.consumeHandoff()
        } catch {
            return errorJSON(
                kind: "handoff_budget_exhausted",
                detail: "8-hop per-turn cap reached"
            )
        }

        guard let domainAgent = await resolver.resolve(domain: args.domain) else {
            return errorJSON(
                kind: "domain_not_found",
                detail: args.domain
            )
        }

        // Build a domain runtime context for this hop. Carry only what
        // the domain needs; no transcript replay in v1.
        let activeDomains = await resolver.listActive()
        let runtime = RuntimeContext(
            now: clock(),
            localTimezone: timezone,
            conversationState: .inFreeChat,
            emptyStateBranch: nil,
            mercyMode: .off,
            pauseUntil: nil,
            activeDomains: activeDomains,
            openCommitments: [],
            recentEventsSummary: nil,
            memoryHitsSummary: nil,
            todayCalendarSummary: nil,
            userMessage: args.message,
            priorTurnSummary: "(handoff from coordinator)"
        )

        let prompt = domainAgent.systemPrompt(runtime: runtime)

        // Domain agent gets ITS scoped tool subset. agent.handoff is NOT
        // in domain scope, so domain agents cannot themselves hand off
        // (architecturally simpler — coordinator stays the orchestration
        // hub; domains never recurse into other domains).
        let domainTools = await registry.tools(in: domainAgent.scope.allowedTools)

        do {
            let session = try await factory.makeSession(
                systemPrompt: prompt.text,
                tools: domainTools,
                temperature: temperature
            )
            let reply = try await session.respond(to: args.message)
            let payload = HandoffResultPayload(
                domain: args.domain,
                text: reply.text,
                toolInvocationCount: reply.toolInvocations.count
            )
            let data = try JSONEncoder().encode(payload)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return errorJSON(
                kind: "domain_session_failed",
                detail: String(describing: error)
            )
        }
    }

    // MARK: - JSON helpers

    private struct HandoffArgs: Codable {
        let domain: String
        let message: String
    }

    private struct HandoffResultPayload: Codable {
        let domain: String
        let text: String
        let toolInvocationCount: Int
    }

    private func errorJSON(kind: String, detail: String) -> String {
        // Deslop S7: hand-rolled string escaping doesn't cover newlines /
        // control chars / unicode quirks. Use JSONEncoder on a real dict
        // so the output is always valid JSON.
        let payload: [String: String] = ["error": kind, "detail": detail]
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys] // stable, diff-friendly
        if let data = try? enc.encode(payload),
           let s = String(data: data, encoding: .utf8)
        {
            return s
        }
        // Encoding [String:String] cannot realistically fail; on the
        // pathological "out of memory" case fall back to a minimal but
        // valid JSON object so the LLM still sees a parseable tool result.
        return "{\"error\":\"\(kind)\"}"
    }
}
