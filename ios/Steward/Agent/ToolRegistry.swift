//
//  ToolRegistry.swift
//  Steward — Track B
//
//  Lookup surface for concrete `LLMTool` implementations. Track C lands
//  the real instrument/event/memory tools; Track D the calendar/reminder/
//  notification tools. Both register against this protocol so the
//  AgentLoop never sees concrete types — only `LLMTool` + `ToolID`.
//

import Foundation

public protocol ToolRegistry: Sendable {
    /// Look up a tool by its typed ID. Returns nil if the ID isn't
    /// registered (e.g. Track C hasn't landed its tool yet); the AgentLoop
    /// surfaces a typed `toolNotFound` to the LLM as a structured error.
    func tool(for id: ToolID) async -> (any LLMTool)?

    /// All registered tools, filtered to those whose `ToolID` is in
    /// `allowedTools`. Used by CoordinatorAgent / DomainAgent to construct
    /// the per-turn tool list handed to the LLMSession factory.
    func tools(in allowedTools: Set<ToolID>) async -> [any LLMTool]
}

/// Map-backed registry. Useful for tests; also the assembly point Tracks
/// C and D wire their concrete tools into in production.
public actor MapToolRegistry: ToolRegistry {
    private var byID: [ToolID: any LLMTool]

    public init(tools: [ToolID: any LLMTool] = [:]) {
        self.byID = tools
    }

    public func register(_ tool: any LLMTool, as id: ToolID) {
        byID[id] = tool
    }

    public func tool(for id: ToolID) async -> (any LLMTool)? {
        return byID[id]
    }

    public func tools(in allowedTools: Set<ToolID>) async -> [any LLMTool] {
        return byID
            .filter { allowedTools.contains($0.key) }
            .map { $0.value }
    }
}
