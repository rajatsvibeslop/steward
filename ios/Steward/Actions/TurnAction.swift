//
//  TurnAction.swift
//  Steward
//
//  Implementation-addendum §1.6: TurnAction + typed InverseAction. Every
//  external mutation an agent makes is paired with a typed inverse so the
//  Settings "Recent agent actions" UI can offer one-tap undo.
//
//  HARD REJECT #4: switching on InverseAction is exhaustive WITHOUT a
//  `default:` arm. Adding a new case must produce a compiler error in
//  UndoExecutor.swift until its handler is written. There is also no
//  `case noop` — actions without an inverse are not undoable and don't
//  produce a TurnAction at all (chat replies, etc.).
//

import Foundation

// MARK: - Identity types

/// ULID-shaped identifier. We don't depend on a ULID library — a 16-byte UUID
/// rendered uppercase is enough for ordering by created_at; not lexicographic
/// time-sort like a real ULID, but the events table indexes on created_at
/// anyway. Pod B can swap in a real ULID generator later without touching
/// callers.
struct ActionID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static func generate() -> ActionID {
        ActionID(rawValue: UUID().uuidString)
    }
}

struct TurnID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static func generate() -> TurnID {
        TurnID(rawValue: UUID().uuidString)
    }
}

struct EventID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static func generate() -> EventID {
        EventID(rawValue: UUID().uuidString)
    }
}

struct MemoryID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

struct NotificationID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static func generate() -> NotificationID {
        NotificationID(rawValue: UUID().uuidString)
    }
}

// MARK: - Actor reference

/// Who performed the action. The events table CHECK constraint requires
/// `reasoning` to be set whenever `actor LIKE 'agent:%' OR actor='coordinator'`
/// (hard reject #11). `ActorRef.dbValue` matches that string vocabulary.
enum ActorRef: Codable, Sendable, Equatable, Hashable {
    case user
    case system
    case coordinator
    case agent(domain: String)

    var dbValue: String {
        switch self {
        case .user:        return "user"
        case .system:      return "system"
        case .coordinator: return "coordinator"
        case .agent(let d): return "agent:\(d)"
        }
    }

    /// Inverse of `dbValue`. Returns nil if the column is malformed (e.g. an
    /// old "agent:" with no domain) — callers handle that as a soft error so
    /// the audit log never gates the app on bad legacy data.
    static func parse(_ raw: String) -> ActorRef? {
        switch raw {
        case "user": return .user
        case "system": return .system
        case "coordinator": return .coordinator
        default:
            guard raw.hasPrefix("agent:") else { return nil }
            let domain = String(raw.dropFirst("agent:".count))
            return domain.isEmpty ? nil : .agent(domain: domain)
        }
    }

    /// `true` when the events CHECK constraint requires `reasoning`. Used by
    /// AuditLog to fail fast in DEBUG if reasoning is empty.
    var requiresReasoning: Bool {
        switch self {
        case .user, .system: return false
        case .coordinator, .agent: return true
        }
    }
}

// MARK: - Calendar / Reminder payloads (used by InverseAction)

/// Snapshot of an EKEvent at write time, big enough to recreate it on undo.
struct CalendarEventPayload: Codable, Sendable, Equatable {
    var title: String
    var startDate: Date
    var endDate: Date
    var notes: String?
    var calendarIdentifier: String?    // EKCalendar.calendarIdentifier
    var calendarName: String?          // last-known display name for UI
    var isAllDay: Bool
    var location: String?
    /// Stable EventKit identifier captured at write time. Used so that undo of
    /// a `modify` knows which EKEvent to re-write.
    var ekEventID: String?

    init(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String? = nil,
        calendarIdentifier: String? = nil,
        calendarName: String? = nil,
        isAllDay: Bool = false,
        location: String? = nil,
        ekEventID: String? = nil
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.calendarIdentifier = calendarIdentifier
        self.calendarName = calendarName
        self.isAllDay = isAllDay
        self.location = location
        self.ekEventID = ekEventID
    }
}

struct ReminderPayload: Codable, Sendable, Equatable {
    var title: String
    var dueDate: Date?
    var notes: String?
    var listIdentifier: String?
    var listName: String?
    var ekReminderID: String?

    init(
        title: String,
        dueDate: Date? = nil,
        notes: String? = nil,
        listIdentifier: String? = nil,
        listName: String? = nil,
        ekReminderID: String? = nil
    ) {
        self.title = title
        self.dueDate = dueDate
        self.notes = notes
        self.listIdentifier = listIdentifier
        self.listName = listName
        self.ekReminderID = ekReminderID
    }
}

// MARK: - Notification request (used by InverseAction and NotificationScheduler)

struct NotificationRequest: Codable, Sendable, Equatable {
    var kind: NotificationKind
    var domain: String?
    var instrumentID: String?
    var fireAt: Date
    var templateContext: TemplateContext
    /// Opaque JSON the tap handler reads to drive a one-turn coordinator
    /// response. Templates cannot read it — bodies stay deterministic.
    var actionContextJSON: String?
    /// Tie-breaker for cap math when several requests are valid at once.
    /// Coordinator-emitted requests outrank domain-agent ones; morning brief
    /// always wins. Higher = more important.
    var priority: Int

    init(
        kind: NotificationKind,
        domain: String? = nil,
        instrumentID: String? = nil,
        fireAt: Date,
        templateContext: TemplateContext,
        actionContextJSON: String? = nil,
        priority: Int = 0
    ) {
        self.kind = kind
        self.domain = domain
        self.instrumentID = instrumentID
        self.fireAt = fireAt
        self.templateContext = templateContext
        self.actionContextJSON = actionContextJSON
        self.priority = priority
    }
}

// MARK: - InverseAction (the heart of undo)

/// Typed inverse for every undoable external mutation. No `case noop` —
/// non-undoable actions don't produce a TurnAction at all.
///
/// HARD REJECT #4 enforcement: `UndoExecutor.execute(_:)` switches on this
/// without a `default:` arm. Adding a new case forces the compiler to flag
/// the executor.
enum InverseAction: Codable, Sendable, Equatable {
    /// Undo a `calendar.delete` — restore the event from its captured payload.
    case restoreCalendarEvent(payload: CalendarEventPayload)

    /// Undo a `calendar.write` — delete the event we created.
    case deleteCalendarEvent(ekEventID: String, calendarIdentifier: String?)

    /// Undo a `calendar.modify` — re-write the event to its pre-modification
    /// state. The original `ekEventID` is preserved so the event keeps its
    /// position in the user's calendar UI.
    case modifyCalendarEvent(ekEventID: String, restoreTo: CalendarEventPayload)

    /// Undo a `reminder.complete` or `reminder.delete` (if we ever ship it).
    case recreateReminder(payload: ReminderPayload)

    /// Undo a `reminder.create`.
    case deleteReminder(ekReminderID: String, listIdentifier: String?)

    /// Undo a `notification.cancel` — re-schedule using the original request.
    case rescheduleNotification(request: NotificationRequest)

    /// Undo a `notification.schedule` — cancel the scheduled notification.
    case cancelNotification(notificationID: String)

    /// Undo a `notification.schedule_recurring` — cancel the recurring rule
    /// AND any of its pending occurrences. Without this, undoing a recurring
    /// schedule would cancel today's occurrence but the next `topUpHorizon`
    /// would re-issue it from the still-active rule row (deslop regression B).
    case cancelRecurringRule(ruleID: String)

    /// Replay all events for the instrument EXCEPT this one and recompute
    /// state from `initialState`. Cheap because instrument event cardinality
    /// is daily (addendum §1.6).
    case revertInstrumentEvent(instrumentID: String, eventIDToReverse: EventID)

    /// Undo a `domain.archive` — clear `archived_at`.
    case archiveDomain(domain: String, archivedAt: Date)

    /// Undo a `domain.create` (or its `unarchive`).
    case unarchiveDomain(domain: String)

    /// Undo a `memory.forget` — restore the soft-deleted memory row.
    case forgetMemory(memoryID: MemoryID)

    /// Undo a `memory.save` — re-soft-delete the memory.
    case unforgetMemory(memoryID: MemoryID)
}

// MARK: - TurnAction

/// One agent-emitted external mutation, paired with its inverse and a
/// reasoning string. Persisted into `events.payload_json` under key
/// `turn_action`; UndoExecutor reads by event_id.
struct TurnAction: Codable, Sendable {
    let id: ActionID
    let turnID: TurnID
    let toolID: ToolID
    let actor: ActorRef
    let executedAt: Date
    /// Agent's stated reason — REQUIRED per hard reject #11. AuditLog asserts
    /// non-empty for `coordinator` / `agent:*` actors.
    let reasoning: String
    let inverse: InverseAction
    /// IDs of dependent actions that must be reversed before this one can be
    /// undone (v1.1 fills this; v1 leaves it empty).
    let cascades: [ActionID]

    init(
        id: ActionID = .generate(),
        turnID: TurnID,
        toolID: ToolID,
        actor: ActorRef,
        executedAt: Date = Date(),
        reasoning: String,
        inverse: InverseAction,
        cascades: [ActionID] = []
    ) {
        self.id = id
        self.turnID = turnID
        self.toolID = toolID
        self.actor = actor
        self.executedAt = executedAt
        self.reasoning = reasoning
        self.inverse = inverse
        self.cascades = cascades
    }
}

// MARK: - Undo outcomes

enum UndoOutcome: Sendable, Equatable {
    case undone(originalEventID: EventID, undoEventID: EventID)
    case blockedByDependents([ActionID])
    case alreadyUndone(originalEventID: EventID)
    case notFound(originalEventID: EventID)
}

/// Kind tag for `InverseAction`. Used in `UndoExecutorError.notYetImplemented`
/// so cross-pod cases (memory / domain / instrument event-replay) can throw a
/// typed "Pod C hasn't wired this yet" error WITHOUT introducing a `default:`
/// arm in the undo switch (hard reject #4). Adding an InverseAction case must
/// also add a kind case here — the test in `UndoExecutorTests` asserts parity.
enum InverseActionKind: String, Codable, Sendable, CaseIterable {
    case restoreCalendarEvent
    case deleteCalendarEvent
    case modifyCalendarEvent
    case recreateReminder
    case deleteReminder
    case rescheduleNotification
    case cancelNotification
    case cancelRecurringRule
    case revertInstrumentEvent
    case archiveDomain
    case unarchiveDomain
    case forgetMemory
    case unforgetMemory
}

extension InverseAction {
    var kind: InverseActionKind {
        switch self {
        case .restoreCalendarEvent:    return .restoreCalendarEvent
        case .deleteCalendarEvent:     return .deleteCalendarEvent
        case .modifyCalendarEvent:     return .modifyCalendarEvent
        case .recreateReminder:        return .recreateReminder
        case .deleteReminder:          return .deleteReminder
        case .rescheduleNotification:  return .rescheduleNotification
        case .cancelNotification:      return .cancelNotification
        case .cancelRecurringRule:     return .cancelRecurringRule
        case .revertInstrumentEvent:   return .revertInstrumentEvent
        case .archiveDomain:           return .archiveDomain
        case .unarchiveDomain:         return .unarchiveDomain
        case .forgetMemory:            return .forgetMemory
        case .unforgetMemory:          return .unforgetMemory
        }
    }
}

enum UndoExecutorError: Error, CustomStringConvertible, Sendable {
    case eventPayloadMissing(EventID)
    case eventPayloadInvalid(EventID, underlying: Error)
    case notYetImplemented(InverseActionKind)
    case ekEventNotFound(ekEventID: String)
    case ekStoreUnavailable
    case backendFailure(String)

    var description: String {
        switch self {
        case .eventPayloadMissing(let id):
            return "events.payload_json for \(id.rawValue) has no `turn_action` entry."
        case .eventPayloadInvalid(let id, let underlying):
            return "events.payload_json for \(id.rawValue) failed to decode: \(underlying)"
        case .notYetImplemented(let k):
            return "Undo handler for \(k.rawValue) is not implemented in v1 — owner pod hasn't landed."
        case .ekEventNotFound(let id):
            return "EventKit event \(id) not found — already removed or store revoked."
        case .ekStoreUnavailable:
            return "EventKit store unavailable; permission may have been revoked."
        case .backendFailure(let msg):
            return "Undo backend failure: \(msg)"
        }
    }
}
