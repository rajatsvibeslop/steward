//
//  DomainAgent.swift
//  Steward — Track B
//
//  One DomainAgent per active row in the `domains` table. Carries:
//   - the user-set `role_prompt` (one of the three RolePromptTemplates or
//     freeform if the user edited it),
//   - a scoped `ToolScope` that pins `domain=<self.domain>` on every tool
//     taking a `domain` arg,
//   - its own per-turn system prompt assembled via PromptAssembler.
//
//  Domain agents are NOT chat-facing in v1 — they reach the user only
//  through the coordinator's reply (the coordinator either summarizes the
//  domain agent's response or relays it verbatim).
//

import Foundation

public struct DomainAgent: Sendable {
    public let domain: String
    public let displayName: String
    /// The role_prompt stored in the `domains` row. Passed straight into
    /// the PromptAssembler's role_prompt segment. Sandwiched between the
    /// two `<<INVARIANT>>` blocks (§1.7) so the user cannot relax the
    /// anti-moralization rules by editing it.
    public let rolePrompt: String

    public let promptAssembler: PromptAssembler

    public init(
        domain: String,
        displayName: String,
        rolePrompt: String,
        promptAssembler: PromptAssembler = PromptAssembler()
    ) {
        self.domain = domain
        self.displayName = displayName
        self.rolePrompt = rolePrompt
        self.promptAssembler = promptAssembler
    }

    public var scope: ToolScope { ToolScope.domain(domain) }

    public func systemPrompt(runtime: RuntimeContext) -> AssembledPrompt {
        return promptAssembler.assemble(
            for: .domain(domain),
            runtime: runtime,
            scope: scope
        )
    }
}
