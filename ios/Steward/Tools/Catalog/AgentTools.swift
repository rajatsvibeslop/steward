//
//  AgentTools.swift
//  Steward
//
//  Spec §8 cross-agent: agent.handoff / agent.cross_consult. These are
//  catalog-level **signatures only** — the bodies live inside Track B's
//  AgentLoop (the handoff loop wraps the entire coordinator→domain dispatch
//  and is conceptually part of the loop state machine, not a leaf tool).
//
//  Track C exposes the schemas so the tool catalog enumeration is complete
//  and so any deserialization tests can round-trip the arg shapes. When Pod
//  B wires up its loop, it overrides these implementations by registering
//  its own `LLMTool` conformances with the same `id`.
//

import Foundation

// MARK: - agent.handoff (signature placeholder)

struct AgentHandoffArgs: Codable, Equatable, Sendable {
    let domain: String
    let message: String
    let reasoning: String
}

struct AgentHandoffPlaceholderResult: Codable, Equatable, Sendable {
    let status: String       // always "delegated_to_loop"
    let message: String      // explanatory
}

struct AgentHandoffTool: LLMTool {
    let id: String = ToolID.agentHandoff.rawValue
    let description: String = "Coordinator-only: delegate the current turn to a named domain agent. The agent loop owns dispatch."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["domain", "message", "reasoning"],
      "properties": {
        "domain": {"type": "string"},
        "message": {"type": "string"},
        "reasoning": {"type": "string"}
      }
    }
    """

    /// Placeholder implementation. Track B's AgentLoop intercepts
    /// `agent.handoff` calls BEFORE dispatching to a tool handler — this
    /// invoke() should never run in production. If it does, surface a
    /// typed error so we get a loud signal during integration.
    func invoke(argsJSON: String) async throws -> String {
        _ = try ToolJSON.decode(AgentHandoffArgs.self, from: argsJSON)
        throw LLMToolError(
            code: "handoff_not_intercepted",
            message: "agent.handoff was dispatched as a leaf tool — AgentLoop should have caught it. This indicates a wiring bug in Track B."
        )
    }
}

// MARK: - agent.cross_consult (signature placeholder)

struct AgentCrossConsultArgs: Codable, Equatable, Sendable {
    let domain: String
    let question: String
    let reasoning: String
}

struct AgentCrossConsultTool: LLMTool {
    let id: String = ToolID.agentCrossConsult.rawValue
    let description: String = "Coordinator-only: ask a domain agent a question without full handoff."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["domain", "question", "reasoning"],
      "properties": {
        "domain": {"type": "string"},
        "question": {"type": "string"},
        "reasoning": {"type": "string"}
      }
    }
    """

    func invoke(argsJSON: String) async throws -> String {
        _ = try ToolJSON.decode(AgentCrossConsultArgs.self, from: argsJSON)
        throw LLMToolError(
            code: "cross_consult_not_intercepted",
            message: "agent.cross_consult was dispatched as a leaf tool — AgentLoop should have caught it."
        )
    }
}
