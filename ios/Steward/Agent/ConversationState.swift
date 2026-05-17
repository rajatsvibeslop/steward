//
//  ConversationState.swift
//  Steward — Track B
//
//  Tracks where the user is in the coordinator empty-state script
//  (design/coordinator-empty-state-v2.md). The AgentLoop owns the
//  authoritative state per session; PromptAssembler reads it to emit a
//  MOCK_HINT marker (consumed by MockLLMSession; ignored by real FM as
//  free-floating system-prompt text).
//
//  This is an enum, not a string-keyed dictionary — §4 #9 forbids
//  string-keyed kind dispatch.
//

import Foundation

public enum ConversationState: Sendable, Equatable, Hashable, Codable {
    /// User has never spoken; UI rendered the §1.1 greeting bubble.
    case awaitingFirstMessage
    /// Branch A — coordinator just acknowledged a captured event and may
    /// offer a retroactive track.
    case capturedAwaitingTrackOffer
    /// Branch B — coordinator just asked the open question; user's next
    /// reply names a life area.
    case awaitingLifeAreaAnswer
    /// Branch B — coordinator proposed a team shape; user is choosing tone.
    case proposingDomain
    /// User said "yes" to a domain proposal; coordinator about to spawn
    /// `domain.create` + propose the first instrument.
    case awaitingDomainConfirm
    /// Coordinator proposed an instrument; user is choosing yes/different/skip.
    case proposingInstrument
    /// User said yes to instrument; coordinator about to spawn it then
    /// ask cadence.
    case awaitingInstrumentConfirm
    /// Branch C — monosyllabic; coordinator offered a concrete on-ramp.
    case unclearOnRamp
    /// Empty-state script has exited; coordinator runs from regular system
    /// prompt for all subsequent turns.
    case inFreeChat

    /// Stable token MockLLMSession reads from the system prompt to
    /// disambiguate the six canned turns. Real FM ignores it.
    public var mockHintToken: String {
        switch self {
        case .awaitingFirstMessage:        return "awaiting_first_message"
        case .capturedAwaitingTrackOffer:  return "captured_awaiting_track_offer"
        case .awaitingLifeAreaAnswer:      return "awaiting_life_area_answer"
        case .proposingDomain:             return "proposing_domain"
        case .awaitingDomainConfirm:       return "awaiting_domain_confirm"
        case .proposingInstrument:         return "proposing_instrument"
        case .awaitingInstrumentConfirm:   return "awaiting_instrument_confirm"
        case .unclearOnRamp:               return "unclear_on_ramp"
        case .inFreeChat:                  return "free_chat"
        }
    }
}

/// Which empty-state branch routed this turn. Set by `EmptyStateRouter`
/// pre-LLM; consumed by `PromptAssembler` and `AgentLoop` for state
/// transitions.
public enum EmptyStateBranch: Sendable, Equatable, Hashable, Codable {
    case branchACaptureFirst
    case branchBSetupFirst
    case branchCUnclear

    public var mockHintToken: String {
        switch self {
        case .branchACaptureFirst: return "branch_a"
        case .branchBSetupFirst:   return "branch_b"
        case .branchCUnclear:      return "branch_c"
        }
    }
}
