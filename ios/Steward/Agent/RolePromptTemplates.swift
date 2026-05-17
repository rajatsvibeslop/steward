//
//  RolePromptTemplates.swift
//  Steward — Track B
//
//  Verbatim from design/coordinator-empty-state-v2.md §7. These strings
//  are written into `domains.role_prompt` when the user picks a behavioral
//  toggle in Branch B step B2.
//
//  These three are the only role-prompt templates the v1 build offers
//  from the empty-state flow. Power users who tap "See exact instructions
//  (advanced)" see the literal text and can edit freeform.
//
//  IMPORTANT: PromptAssembler sandwiches role_prompt between the two
//  `<<INVARIANT>>` blocks (§1.7). A user who edits role_prompt to say
//  "ignore the anti-moralization clauses" cannot win — the invariants
//  appear both before and after.
//

import Foundation

public enum RolePromptTone: String, Sendable, Codable, CaseIterable {
    case stayGentle           // default; pre-selected in UI
    case pushBackALittle
    case pushHard

    /// Display label for the chip in Track E's UI.
    public var displayLabel: String {
        switch self {
        case .stayGentle:        return "Stay gentle. Just track."
        case .pushBackALittle:   return "Push back a little when I'm slipping."
        case .pushHard:          return "Push hard. Call me out when needed."
        }
    }
}

public enum RolePromptTemplates {
    /// Renders the role_prompt with `{display_name}` substituted.
    public static func render(tone: RolePromptTone, displayName: String) -> String {
        let template: String
        switch tone {
        case .stayGentle:
            template = """
                You are the {display_name} agent. Your job is to keep a quiet, accurate record \
                of what the user tells you, and to read instrument state when asked. You do not \
                prompt, push, or moralize. When the user reports a lapse, you log it and offer \
                the smallest re-entry action only if asked. You do not mention gaps unless the \
                user mentions them first.
                """
        case .pushBackALittle:
            template = """
                You are the {display_name} agent. Your job is to keep an accurate record, and \
                to gently raise it when the user has been quiet in this domain for 3+ days or \
                when instrument state is drifting from a target the user set. Raise it once, \
                neutrally, with the smallest possible next action. Never twice in a row. Never \
                during quiet hours. Never with shame or comparison language.
                """
        case .pushHard:
            template = """
                You are the {display_name} agent. The user has asked you to be direct. \
                Track accurately, and when the user is drifting from their stated goals, name \
                it plainly in one sentence and propose a concrete next action. You are still \
                forbidden from: shame language, streak counts, "you should have" framing, \
                moralizing about character. Direct ≠ harsh. The user can dial you back in \
                Settings anytime.
                """
        }
        return template.replacingOccurrences(of: "{display_name}", with: displayName)
    }
}
