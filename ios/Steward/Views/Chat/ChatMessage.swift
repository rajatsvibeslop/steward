//
//  ChatMessage.swift
//  Steward — Track E
//
//  One row in the chat transcript. Tool-call cards are first-class items so
//  they render inline between bubbles per Designer §1.3 (NOT inside the
//  assistant's bubble — "as a separate card below the most recent assistant
//  bubble that produced them").
//
//  These are view-model types only. The persisted history lives in `events`;
//  the ChatViewModel projects events into ChatMessages and prepends/appends
//  live entries as the user sends.
//

import Foundation

/// One transcript row.
struct ChatMessage: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let body: Body

    enum Body: Equatable {
        case user(text: String)
        case coordinator(text: String, isStub: Bool)
        case domain(domainKey: String, displayName: String, text: String, isStub: Bool)
        case toolCallCard(ToolCallSummary)
        case handoffIndicator(domainKey: String, displayName: String)
        case thinkingCoordinator
        case thinkingDomain(domainKey: String, displayName: String)
        case systemNote(text: String)
        case stillWorkingNote
    }
}

/// A single tool invocation captured for rendering. We don't keep a reference
/// to the raw `LLMToolInvocation` because the UI projects it into Designer's
/// verb/object format up-front (per §1.3) so the row renders deterministically
/// regardless of args payload shape.
struct ToolCallSummary: Equatable {
    /// The agent/persona that called the tool ("Steward" for coordinator,
    /// "{Domain} team" for a domain agent). UI displays the actor short name
    /// in the collapsed row.
    let actorLabel: String

    /// Domain identifier when the actor is a domain agent, else nil. Used to
    /// color the leading accent of the row.
    let domainKey: String?

    /// "updated" / "logged" / "wrote down" — verb table entry.
    let verb: String

    /// "weight_trend" / "Call Mom" / "an event" — object table entry.
    let object: String

    /// Full tool ID (e.g. "instrument.apply_event"). Drives undo eligibility
    /// + the monospaced "What" line in the expanded card.
    let toolID: String

    /// Pretty single-line representation of args, for the "What" section. We
    /// generate this from the args JSON deterministically (key=value list)
    /// rather than calling the LLM.
    let argsSummary: String

    /// Plain-prose "Why" line from `TurnAction.reasoning` if available.
    let reasoning: String?

    /// One-line "Result" copy from the tool dispatcher.
    let resultSummary: String

    /// The events row this tool-call landed in audit log, if any. Used by the
    /// inline `Undo` action — falls back to `nil` for non-auditable calls
    /// (read-only tools).
    let eventID: String?

    /// True iff the underlying tool produces an InverseAction the UndoExecutor
    /// can reverse (covers calendar, reminder, notification, instrument,
    /// memory, domain, commitment). Drives whether the Undo button shows.
    let isReversible: Bool

    /// True iff the inline "Show in Today" deep link applies — see §1.3.
    let supportsShowInToday: Bool
}
