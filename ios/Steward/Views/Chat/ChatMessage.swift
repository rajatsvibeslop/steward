//
//  ChatMessage.swift
//  Steward
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
        /// Inline permission-grant card (addendum §1.9). Rendered when a
        /// tool throws `PermissionRequiredSignal` or
        /// `HealthPermissionRequiredSignal` mid-turn. The user taps Allow to
        /// run the OS permission sheet; on grant, ChatViewModel auto-retries
        /// the pending tool call once.
        case permissionPrompt(PermissionPromptModel)
    }
}

/// Static descriptor for a permission-prompt bubble. Carries the scope
/// (rendered as copy), the kind (drives which gateway to call on Allow),
/// and the pending tool call (re-fired on grant). `state` flips from
/// `.awaitingTap` → `.requesting` → `.resolved` so the bubble updates
/// without being replaced in the transcript (preserves scroll position).
struct PermissionPromptModel: Equatable {
    enum Kind: Equatable {
        case eventKitCalendarFull
        case eventKitCalendarWrite
        case eventKitRemindersFull
        case eventKitRemindersWrite
        case healthKitReadAll
    }

    enum State: Equatable {
        case awaitingTap
        case requesting
        case resolved(text: String)
    }

    let kind: Kind
    let pendingToolID: String?
    let pendingArgsJSON: String?
    var state: State

    var title: String {
        switch kind {
        case .eventKitCalendarFull, .eventKitCalendarWrite:
            return "Calendar access"
        case .eventKitRemindersFull, .eventKitRemindersWrite:
            return "Reminders access"
        case .healthKitReadAll:
            return "Health access"
        }
    }

    /// UXR v2 voice: direct ask, no moralization, no privacy hedge.
    var body: String {
        switch kind {
        case .eventKitCalendarFull, .eventKitCalendarWrite:
            return "Outkeep wants to read your calendar to help with scheduling. Allow?"
        case .eventKitRemindersFull, .eventKitRemindersWrite:
            return "Outkeep wants to add reminders for the things you commit to. Allow?"
        case .healthKitReadAll:
            return "Outkeep wants to read your sleep, weight, and step count from Apple Health. Allow?"
        }
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
