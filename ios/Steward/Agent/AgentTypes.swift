//
//  AgentTypes.swift
//  Steward — Track B
//
//  Shared value types for the agent loop. These are deliberately small and
//  free of FoundationModels dependencies so other pods (C, D) can pull
//  them in without breaking the gating contract from addendum §4 #20.
//

import Foundation

// MARK: - Identifiers

/// Opaque ULID-ish string identifier for one user-initiated turn. Generated
/// in `AgentLoop.run(userMessage:)` from Date + a small random suffix; the
/// production path is allowed to use random — only MockLLMSession's reply
/// payloads must avoid non-determinism (§4 #21).
public struct TurnID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String
    public init(raw: String) { self.raw = raw }
    public var description: String { raw }
}

public struct ActionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String
    public init(raw: String) { self.raw = raw }
    public var description: String { raw }
}

// MARK: - Roles

/// Who is running the LLM call. Enum, not string — §4 #9 forbids string-keyed
/// kind dispatch. Coordinator and DomainAgent each construct the right
/// AgentRole; PromptAssembler switches on this.
public enum AgentRole: Sendable, Equatable, Hashable {
    case coordinator
    case domain(String) // domain identifier ("health", "money", ...)
}

/// Audit-log identity of who took a recorded action. Mirrors the
/// `events.actor` column from spec §5 + addendum §4 #11.
public enum ActorRef: Sendable, Equatable, Hashable, Codable {
    case user
    case system
    case coordinator
    case agent(domain: String)

    /// String form for persistence (`events.actor` text column).
    public var dbActor: String {
        switch self {
        case .user: return "user"
        case .system: return "system"
        case .coordinator: return "coordinator"
        case .agent(let domain): return "agent:\(domain)"
        }
    }
}

// MARK: - Runtime context

/// Everything PromptAssembler needs to assemble a system prompt for a turn.
/// Sub-pods fill the fields they care about; missing fields render to empty
/// segments (PromptAssembler skips them rather than emitting "(none)").
public struct RuntimeContext: Sendable, Equatable {
    public var now: Date
    public var localTimezone: TimeZone
    public var conversationState: ConversationState
    public var emptyStateBranch: EmptyStateBranch?
    public var mercyMode: MercyMode
    public var pauseUntil: Date?
    public var activeDomains: [DomainSummary]
    public var openCommitments: [CommitmentSummary]
    public var recentEventsSummary: String?
    public var memoryHitsSummary: String?
    public var todayCalendarSummary: String?
    /// The user-visible message currently being processed. NEVER trimmed.
    public var userMessage: String
    /// Optional prior-turn compaction; injected when running multi-turn.
    public var priorTurnSummary: String?

    public init(
        now: Date,
        localTimezone: TimeZone,
        conversationState: ConversationState,
        emptyStateBranch: EmptyStateBranch?,
        mercyMode: MercyMode,
        pauseUntil: Date?,
        activeDomains: [DomainSummary],
        openCommitments: [CommitmentSummary],
        recentEventsSummary: String?,
        memoryHitsSummary: String?,
        todayCalendarSummary: String?,
        userMessage: String,
        priorTurnSummary: String?
    ) {
        self.now = now
        self.localTimezone = localTimezone
        self.conversationState = conversationState
        self.emptyStateBranch = emptyStateBranch
        self.mercyMode = mercyMode
        self.pauseUntil = pauseUntil
        self.activeDomains = activeDomains
        self.openCommitments = openCommitments
        self.recentEventsSummary = recentEventsSummary
        self.memoryHitsSummary = memoryHitsSummary
        self.todayCalendarSummary = todayCalendarSummary
        self.userMessage = userMessage
        self.priorTurnSummary = priorTurnSummary
    }
}

public enum MercyMode: Sendable, Equatable, Hashable {
    case off
    case on(until: Date?)
}

public struct DomainSummary: Sendable, Equatable, Hashable, Codable {
    public let domain: String
    public let displayName: String
    public init(domain: String, displayName: String) {
        self.domain = domain
        self.displayName = displayName
    }
}

public struct CommitmentSummary: Sendable, Equatable, Hashable, Codable {
    public let title: String
    public let dueAt: Date?
    public let domain: String?
    public init(title: String, dueAt: Date?, domain: String?) {
        self.title = title
        self.dueAt = dueAt
        self.domain = domain
    }
}

// MARK: - Turn outcome

/// What the AgentLoop returns to the caller after one user message.
public struct CoordinatorResponse: Sendable, Equatable {
    public let turnID: TurnID
    public let text: String
    public let backendKind: LLMBackendKind
    public let toolInvocations: [LLMToolInvocation]
    public let handoffsConsumed: Int
    public let budgetExhausted: Bool

    public init(
        turnID: TurnID,
        text: String,
        backendKind: LLMBackendKind,
        toolInvocations: [LLMToolInvocation],
        handoffsConsumed: Int,
        budgetExhausted: Bool
    ) {
        self.turnID = turnID
        self.text = text
        self.backendKind = backendKind
        self.toolInvocations = toolInvocations
        self.handoffsConsumed = handoffsConsumed
        self.budgetExhausted = budgetExhausted
    }
}
