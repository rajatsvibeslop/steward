//
//  AgentTools.swift
//  Steward
//
//  Spec §8 cross-agent tools. The catalog ships `AgentCrossConsultTool`
//  here (a leaf tool with no runtime deps).
//
//  `agent.handoff` is NOT in this file: it's wired in `Agent/AgentLoop.swift`
//  as a real `LLMTool` whose `invoke()` consumes a `TurnBudget` hop and spawns
//  a domain session. That dance can't be a leaf tool because it needs
//  per-turn dependencies (budget, resolver, registry, factory, timezone,
//  clock) and lives inside the handoff state machine.
//
//  `agent.cross_consult` is registered in the catalog but should be
//  intercepted by `AgentLoop` before reaching `invoke()`. If `invoke()`
//  fires, that's a wiring bug — the tool throws to signal it.
//

import Foundation

// MARK: - agent.cross_consult

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
