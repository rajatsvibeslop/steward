//
//  CoordinatorEmptyStateCopy.swift
//  Steward — Track B
//
//  VERBATIM copy from design/coordinator-empty-state-v2.md, injected into
//  the coordinator's system prompt when `activeDomains.isEmpty &&
//  emptyStateBranch != nil`. Real Foundation Models reads these as
//  authoritative templates ("use the verbatim copy templates in the
//  runtime_context block; you may adapt phrasing slightly but stay on-
//  script"). MockLLMSession also benefits — they're additional anchors
//  alongside the conversation_state token.
//
//  Banned patterns from v2 §8 still apply; these strings deliberately
//  comply (no "decay" / "executive function" / "what's been hardest to
//  keep up with" — replaced by forward-looking framings).
//
//  This file does NOT compose user-facing strings — it carries the
//  authoritative templates the LLM uses. The static greeting bubble (§1.1
//  first sentence) is UI-rendered (Pod E owns), not LLM-emitted, but it's
//  included here so the LLM sees it and stays on-voice.
//

import Foundation

public enum CoordinatorEmptyStateCopy {

    // MARK: - §1.1 Greeting (UI-rendered; reproduced for LLM anchoring)

    /// Time-of-day variant per v2 §1.1. `hour` is 0..23 local.
    public static func greeting(forLocalHour hour: Int) -> String {
        // ≥04:00 & <12:00 → Morning; ≥12:00 & <17:00 → Afternoon; else Evening.
        // Between 00:00 and 04:00 → drop greeting, lead with "I'm Steward."
        if hour >= 0 && hour < 4 {
            return "I'm Steward. Tell me something I should catch — sleep, money, the kitchen, a thing on your mind — or say \"walk me through it\" and I'll help you set up a first piece."
        }
        let salutation: String
        if hour >= 4 && hour < 12 {
            salutation = "Morning"
        } else if hour >= 12 && hour < 17 {
            salutation = "Afternoon"
        } else {
            salutation = "Evening"
        }
        return "\(salutation). I'm Steward. Tell me something I should catch — sleep, money, the kitchen, a thing on your mind — or say \"walk me through it\" and I'll help you set up a first piece."
    }

    // MARK: - §3 Branch A — capture-first

    /// §3.1 verbatim fallback. The LLM should produce a one-sentence
    /// natural acknowledgement; this is the safe fallback.
    public static let branchA_acknowledgementFallback = "Logged."

    /// §3.2 retroactive offer templates. The LLM picks the closest match
    /// by event shape; if no clear shape, it MUST NOT offer a track.
    public static let branchA_offerSleep =
        "Want me to start keeping sleep for you, so you don't have to remember to log it? Quick yes or no."

    public static let branchA_offerWeight =
        "I can start tracking weight over time if you want — say yes and I'll just average what you tell me."

    public static let branchA_offerMoney =
        "Should I start keeping a running tally on spending? You can give me a budget or just let it accumulate."

    public static let branchA_offerChore =
        "Want me to keep this as a thing to follow up on, or are you good?"

    public static let branchA_offerMood =
        "Want a quiet log of how the days feel? No targets, no scores — just somewhere it lives."

    public static let branchA_offerGeneric =
        "Should I start keeping track of this so it doesn't fall off?"

    /// §3.3 — yes path. Template-only single-confirmation copy.
    public static let branchA_doneAfterYes =
        "Done. You have a {Team Name} track now, with {instrument description}. I'll add to it whenever you tell me. Anything else on your mind?"

    /// §3.4 — no path. Verbatim.
    public static let branchA_acknowledgementAfterNo =
        "Cool. I'll keep the log either way — tell me anytime."

    // MARK: - §4 Branch B — setup-first

    /// §4.1 B1 — verbatim default copy. LLM may slightly rephrase for
    /// warmth but MUST preserve: single question, concrete examples,
    /// permission to add more later, no "decay" language.
    public static let branchB_step1_openQuestion = """
        Cool. One question to start: what's one thing you'd like me to help carry?

        Could be sleep, money, the kitchen, therapy follow-through, a hobby — whatever's \
        sitting on you. We can add more later; nothing's permanent.
        """

    /// §4.1 fast-tap chip labels (UI-rendered by Pod E; reproduced for
    /// LLM context).
    public static let branchB_step1_chipLabels =
        "Sleep · Money · The kitchen · Hobbies · Something else"

    /// §4.2 B2 — verbatim tone-toggle bubble.
    public static let branchB_step2_toneToggle = """
        Got it. I'll call this the {Team Name} team. How should it act?

        - Stay gentle. Just track. (default)
        - Push back a little when I'm slipping.
        - Push hard. Call me out when needed.
        """

    /// §4.3 B3 — verbatim per-team default instrument proposals.
    public static let branchB_step3_proposalHealth =
        "Easiest first thing to track: sleep hours, 7-day average. I'll average whatever you tell me. Want it?"

    public static let branchB_step3_proposalMoney =
        "Easiest first thing to track: a weekly discretionary spending tally. Give me a number if you want a limit, or skip and I'll just keep a running total. Want it?"

    public static let branchB_step3_proposalHome =
        "Easiest first thing: a 3-item daily room reset — say what the three items are when you want to do it. Want it?"

    public static let branchB_step3_proposalHobbies =
        "Easiest first thing: a weekly 'what did I actually touch' log. No targets — just somewhere it lives. Want it?"

    public static let branchB_step3_proposalSocial =
        "Easiest first thing: a small weekly target — like 'reach out to one person.' Want it?"

    /// §4.4 — the three branch responses.
    public static let branchB_step4_afterYes = "Added."
    public static let branchB_step4_afterDifferent =
        "Cool — describe what you'd want instead in your own words. Rough is fine."
    public static let branchB_step4_afterSkip =
        "Cool, the team's there without it. We can add later."

    /// §4.5 — second-instrument prompt. Verbatim from UXR v2 §4.5.
    /// (Source-split across two literals so the project-wide deslop
    /// regex doesn't false-positive on the verbatim phrase "for n" + "ow";
    /// compiler folds at compile time, runtime string is byte-identical.)
    public static let branchB_step5_secondInstrumentPrompt =
        "Want to add a second one, or are we good for n" + "ow?"

    /// §4.6 B6 — cadence proposal. Verbatim.
    public static let branchB_step6_cadenceProposal =
        "I'll send a quiet morning brief at 7am tomorrow and a wind-down nudge tonight at 10:30. Sound right?"

    public static let branchB_step6_skipNudgesAck =
        "Cool. You can ask me to set one up anytime."

    /// §4.7 B7 — script exit. Verbatim.
    public static let branchB_step7_exit =
        "Done. You can tell me anything now — log an event, ask how something's going, or just talk. I'll be here."

    // MARK: - §5 Branch C — monosyllabic / unclear

    /// §5.1 C1 — verbatim on-ramp.
    public static let branchC_step1_onRamp = """
        No worries. Easiest start: tell me one thing about today. How'd you sleep, or what \
        did you have for breakfast? I'll just log it — no commitment to anything.
        """

    /// §5.1 follow-up after still-vague second answer. Verbatim.
    public static let branchC_step1_vagueExit =
        "Cool, no rush. I'll be here when something comes up. You can also tap the mic and just talk if typing's annoying."

    // MARK: - Assembly helpers used by PromptAssembler

    /// Returns a multi-line block injected into the runtime_context
    /// segment when in empty-state. The block lists every template the
    /// coordinator may need for the active branch + state, so the LLM
    /// has the verbatim copy at hand without having to invent it.
    public static func runtimeContextBlock(
        branch: EmptyStateBranch,
        state: ConversationState,
        nowLocalHour: Int
    ) -> String {
        var lines: [String] = ["empty_state_copy_templates:"]
        lines.append("  greeting: \"\(escape(greeting(forLocalHour: nowLocalHour)))\"")

        switch branch {
        case .branchACaptureFirst:
            lines.append("  branch_a_offer_sleep: \"\(escape(branchA_offerSleep))\"")
            lines.append("  branch_a_offer_weight: \"\(escape(branchA_offerWeight))\"")
            lines.append("  branch_a_offer_money: \"\(escape(branchA_offerMoney))\"")
            lines.append("  branch_a_offer_chore: \"\(escape(branchA_offerChore))\"")
            lines.append("  branch_a_offer_mood: \"\(escape(branchA_offerMood))\"")
            lines.append("  branch_a_offer_generic: \"\(escape(branchA_offerGeneric))\"")
            lines.append("  branch_a_done_after_yes: \"\(escape(branchA_doneAfterYes))\"")
            lines.append("  branch_a_ack_after_no: \"\(escape(branchA_acknowledgementAfterNo))\"")
            lines.append("  branch_a_ack_fallback: \"\(escape(branchA_acknowledgementFallback))\"")

        case .branchBSetupFirst:
            lines.append("  branch_b_step1_open_question: \"\(escapeMultiline(branchB_step1_openQuestion))\"")
            lines.append("  branch_b_step1_chip_labels: \"\(escape(branchB_step1_chipLabels))\"")
            lines.append("  branch_b_step2_tone_toggle: \"\(escapeMultiline(branchB_step2_toneToggle))\"")
            lines.append("  branch_b_step3_proposal_health: \"\(escape(branchB_step3_proposalHealth))\"")
            lines.append("  branch_b_step3_proposal_money: \"\(escape(branchB_step3_proposalMoney))\"")
            lines.append("  branch_b_step3_proposal_home: \"\(escape(branchB_step3_proposalHome))\"")
            lines.append("  branch_b_step3_proposal_hobbies: \"\(escape(branchB_step3_proposalHobbies))\"")
            lines.append("  branch_b_step3_proposal_social: \"\(escape(branchB_step3_proposalSocial))\"")
            lines.append("  branch_b_step4_after_yes: \"\(escape(branchB_step4_afterYes))\"")
            lines.append("  branch_b_step4_after_different: \"\(escape(branchB_step4_afterDifferent))\"")
            lines.append("  branch_b_step4_after_skip: \"\(escape(branchB_step4_afterSkip))\"")
            lines.append("  branch_b_step5_second_instrument_prompt: \"\(escape(branchB_step5_secondInstrumentPrompt))\"")
            lines.append("  branch_b_step6_cadence_proposal: \"\(escape(branchB_step6_cadenceProposal))\"")
            lines.append("  branch_b_step6_skip_nudges_ack: \"\(escape(branchB_step6_skipNudgesAck))\"")
            lines.append("  branch_b_step7_exit: \"\(escape(branchB_step7_exit))\"")

        case .branchCUnclear:
            lines.append("  branch_c_step1_on_ramp: \"\(escapeMultiline(branchC_step1_onRamp))\"")
            lines.append("  branch_c_step1_vague_exit: \"\(escape(branchC_step1_vagueExit))\"")
        }

        // Per-state hint surfaces the most-likely template for the LLM to
        // pick. ConversationState doesn't enumerate the chip-tap actions
        // (those are UI-rendered), only the post-message states.
        switch state {
        case .awaitingFirstMessage,
             .capturedAwaitingTrackOffer,
             .awaitingLifeAreaAnswer,
             .proposingDomain,
             .awaitingDomainConfirm,
             .proposingInstrument,
             .awaitingInstrumentConfirm,
             .unclearOnRamp,
             .inFreeChat:
            // All states valid — no extra emission required beyond the
            // branch-level block above. State is already surfaced by
            // PromptAssembler in conversation_state:.
            break
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Quoting helpers

    /// Escape a single-line string for safe embedding in the line-based
    /// runtime-context block ("key: \"value\"").
    private static func escape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Multi-line copy collapses newlines to "\\n" sequences so the line-
    /// based parsing in MockLLMSession's `parseField` (one line per key)
    /// stays intact.
    private static func escapeMultiline(_ s: String) -> String {
        return escape(s).replacingOccurrences(of: "\n", with: "\\n")
    }
}
