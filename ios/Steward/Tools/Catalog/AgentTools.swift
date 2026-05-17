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

// MARK: - agent.handoff
//
// The canonical `AgentHandoffTool` lives in `Agent/AgentLoop.swift` (Pod B).
// Pod B's AgentLoop registers it when building the coordinator's tool list
// with all the runtime dependencies it needs (budget, resolver, registry,
// factory, temperature, timezone, clock). `ToolCatalog.allTrackCTools()`
// no longer registers a placeholder here — registration is Pod B's job.

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
