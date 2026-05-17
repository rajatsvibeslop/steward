//
//  TurnBudget.swift
//  Steward — Track B
//
//  Per addendum §1.1 — shared cross-agent handoff budget.
//
//  Only `agent.handoff` counts against this. Foundation Models auto-loops
//  internal tool calls via `respond(to:)`; we never count those. Manual
//  tool-call loop = hard reject #7.
//

import Foundation

public struct TurnBudget: Sendable, Equatable {
    public var handoffsRemaining: Int
    public let contextTokenCeiling: Int
    public let startedAt: Date

    public init(
        handoffsRemaining: Int = TurnBudget.defaultHandoffs,
        contextTokenCeiling: Int,
        startedAt: Date
    ) {
        self.handoffsRemaining = handoffsRemaining
        self.contextTokenCeiling = contextTokenCeiling
        self.startedAt = startedAt
    }

    public static let defaultHandoffs: Int = 8
    public static let coordinatorTokenCeiling: Int = 9_000
    public static let domainTokenCeiling: Int = 6_000

    public mutating func consumeHandoff() throws {
        guard handoffsRemaining > 0 else {
            throw AgentError.handoffBudgetExhausted
        }
        handoffsRemaining -= 1
    }
}

/// Errors the AgentLoop and its helpers surface. No `fatalError`/`precondition`
/// in production paths (§4 hard reject #3); all failures route through here
/// or `LLMSessionError`.
public enum AgentError: Error, CustomStringConvertible, Equatable {
    case handoffBudgetExhausted
    case noActiveDomainsForHandoff(requested: String)
    case domainNotFound(domain: String)
    case routingAmbiguous(detail: String)
    case followupOutsideValidWindow
    case settingsLoadFailed(detail: String)

    public var description: String {
        switch self {
        case .handoffBudgetExhausted:
            return "Cross-agent handoff budget exhausted (8 hops max per turn)."
        case .noActiveDomainsForHandoff(let requested):
            return "Handoff requested for '\(requested)' but no matching domain is active."
        case .domainNotFound(let domain):
            return "Domain '\(domain)' not found."
        case .routingAmbiguous(let detail):
            return "Empty-state routing ambiguous: \(detail)"
        case .followupOutsideValidWindow:
            return "Day-0 followup notification computed time is outside [13:00, 17:00]."
        case .settingsLoadFailed(let detail):
            return "Settings load failed: \(detail)"
        }
    }
}
