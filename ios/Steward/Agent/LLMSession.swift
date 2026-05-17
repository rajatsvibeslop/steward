//
//  LLMSession.swift
//  Steward — Track B
//
//  Provider-agnostic abstraction for on-device LLM calls.
//  Per implementation-addendum §1.10 (verbatim signatures).
//
//  Two conformances exist:
//   - MockLLMSession (always compiled; deterministic fixtures + tests)
//   - FoundationModelsSession (gated #if canImport(FoundationModels))
//
//  Hard rule (addendum §4 #20): only FoundationModelsSession.swift and
//  LLMResolver.swift may `import FoundationModels`. Everything else
//  consumes this protocol.
//

import Foundation

// MARK: - Backend identification

/// What backend produced a given response. The UI (Track E) reads this and
/// stamps a `STUB` chip on every `.mock(...)` reply.
public enum LLMBackendKind: Sendable, Codable, Equatable {
    case foundationModels
    case mock(reason: MockReason)
}

/// Typed reasons MockLLMSession is in use. String-keyed dispatch is a hard
/// reject (§4 #9) — every consumer must switch on these exhaustively.
public enum MockReason: String, Sendable, Codable, CaseIterable {
    case sdkNotCompiledIn          // built without iOS 26 SDK — current state
    case modelNotAvailable          // SDK present, device says unavailable
    case modelNotReady              // Apple Intelligence still downloading/preparing
    case appleIntelligenceDisabled  // user turned it off in Settings
    case deviceNotEligible          // hardware not on the Apple Intelligence list
}

// MARK: - Tool surface

/// Universal tool shape. Args + result are JSON strings — the "vocabulary"
/// both Mock and FoundationModels backends speak. FoundationModelsSession
/// bridges this to the `@Generable` macro internally; MockLLMSession invokes
/// tools by `id` after pattern-matching.
public protocol LLMTool: Sendable {
    var id: String { get }
    var description: String { get }
    /// JSON Schema (draft 2020-12 subset) describing the args object.
    var jsonSchemaForArgs: String { get }
    func invoke(argsJSON: String) async throws -> String
}

/// One tool invocation captured for audit. The framework already executed
/// the tool by the time the response surfaces; this is the receipt.
public struct LLMToolInvocation: Sendable, Codable, Equatable {
    public let toolID: String
    public let argsJSON: String
    public let resultJSON: String
    public let executedAt: Date

    public init(toolID: String, argsJSON: String, resultJSON: String, executedAt: Date) {
        self.toolID = toolID
        self.argsJSON = argsJSON
        self.resultJSON = resultJSON
        self.executedAt = executedAt
    }
}

// MARK: - Response

public struct LLMResponse: Sendable, Equatable {
    public let text: String
    public let toolInvocations: [LLMToolInvocation]
    public let backendKind: LLMBackendKind

    public init(text: String, toolInvocations: [LLMToolInvocation], backendKind: LLMBackendKind) {
        self.text = text
        self.toolInvocations = toolInvocations
        self.backendKind = backendKind
    }
}

// MARK: - Session

/// Single-turn LLM session. The implementation auto-loops internal tool
/// calls (Foundation Models does this via `respond(to:)` per addendum §3
/// Foundation Models bullet 1).
///
/// **The agent loop never manually loops tool calls** — only `agent.handoff`
/// is hand-rolled, via its own LLMTool wrapper that consumes a TurnBudget
/// hop. See addendum §4 hard reject #7.
public protocol LLMSession: Actor {
    /// Send one user message, get one final assistant reply. Any tools the
    /// model wants to call run inside this call before returning.
    func respond(to userMessage: String) async throws -> LLMResponse

    /// Discard transcript / KV cache. Call between coordinator turns to
    /// bound memory growth.
    func reset() async
}

/// Factory for creating fresh per-turn sessions. The factory is the unit
/// the resolver returns; the AgentLoop holds it and mints a new session
/// per user turn (addendum §3 FM bullet: "wrap each turn in a fresh
/// LanguageModelSession").
public protocol LLMSessionFactory: Sendable {
    /// Identifies which backend made this factory. Surfaced via every
    /// response so the UI can tag stub replies.
    var backendKind: LLMBackendKind { get }

    func makeSession(
        systemPrompt: String,
        tools: [any LLMTool],
        temperature: Double
    ) async throws -> any LLMSession
}

// MARK: - Errors

/// Errors the LLM layer surfaces. Production code never `fatalError`s
/// (§4 hard reject #3); all failures route through this type.
public enum LLMSessionError: Error, CustomStringConvertible, Equatable {
    case backendUnavailable(reason: MockReason)
    case malformedToolArgs(toolID: String, detail: String)
    case toolNotFound(toolID: String)
    case toolExecutionFailed(toolID: String, underlying: String)
    case invalidResponse(detail: String)

    public var description: String {
        switch self {
        case .backendUnavailable(let reason):
            return "LLM backend unavailable: \(reason.rawValue)"
        case .malformedToolArgs(let toolID, let detail):
            return "Malformed args for tool \(toolID): \(detail)"
        case .toolNotFound(let toolID):
            return "Tool not registered: \(toolID)"
        case .toolExecutionFailed(let toolID, let underlying):
            return "Tool \(toolID) failed: \(underlying)"
        case .invalidResponse(let detail):
            return "Invalid LLM response: \(detail)"
        }
    }
}
