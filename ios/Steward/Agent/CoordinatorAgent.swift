//
//  CoordinatorAgent.swift
//  Steward — Track B
//
//  The coordinator is the only thing the user chats with by default
//  (spec §7). Owns the empty-state flow scripting; uses the
//  PromptAssembler to render its system prompt with the canonical
//  invariant markers; gets the full tool surface (`ToolScope.coordinatorAll`).
//
//  This file is intentionally small — it's a configuration carrier, not a
//  loop. The loop lives in AgentLoop.swift; the prompt construction is in
//  PromptAssembler. Coordinator's job here is to know its role + scope.
//

import Foundation

public struct CoordinatorAgent: Sendable {
    public let promptAssembler: PromptAssembler

    public init(promptAssembler: PromptAssembler = PromptAssembler()) {
        self.promptAssembler = promptAssembler
    }

    /// Coordinator scope: every tool, no arg constraints.
    public var scope: ToolScope { ToolScope.coordinatorAll }

    /// Assemble the coordinator's system prompt for a single turn.
    public func systemPrompt(runtime: RuntimeContext) -> AssembledPrompt {
        return promptAssembler.assemble(
            for: .coordinator,
            runtime: runtime,
            scope: scope
        )
    }
}
