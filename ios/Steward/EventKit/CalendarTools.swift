//
//  CalendarTools.swift
//  Steward
//
//  LLMTool conformances for calendar.* and reminder.*. Each tool:
//   - dispatches through EventKitGateway (NEVER calls EKEventStore.requestAccess
//     directly — that's HARD REJECT #18),
//   - pairs each successful mutation with a typed InverseAction emitted into
//     the audit log via AuditLog (HARD REJECT #11 — reasoning required),
//   - returns a wire-friendly JSON string the LLM can parse,
//   - hides `.permissionRequired` from the LLM (HARD REJECT #19) — that case
//     comes out of `invoke(...)` as a non-LLM-visible ToolError so the UI can
//     intercept and run the inline-grant flow.
//

import Foundation

// MARK: - calendar.read

actor CalendarReadTool: LLMTool {
    let id = ToolID.calendarRead.rawValue
    let description = "Read calendar events between start and end."
    let jsonSchemaForArgs = """
    {"type":"object","properties":{"start":{"type":"string","format":"date-time"},"end":{"type":"string","format":"date-time"},"calendarName":{"type":"string"}},"required":["start","end"]}
    """

    private let gateway: EventKitGateway
    init(gateway: EventKitGateway = .shared) { self.gateway = gateway }

    func invoke(argsJSON: String) async throws -> String {
        let args: CalendarReadArgs = try decode(argsJSON)
        let result = await gateway.executeCalendarRead(args)
        return try wireOrThrow(result)
    }
}

// MARK: - calendar.write

actor CalendarWriteTool: LLMTool {
    let id = ToolID.calendarWrite.rawValue
    let description = "Create a calendar event."
    let jsonSchemaForArgs = """
    {"type":"object","properties":{"title":{"type":"string"},"startDate":{"type":"string","format":"date-time"},"endDate":{"type":"string","format":"date-time"},"notes":{"type":"string"},"calendarName":{"type":"string"},"reasoning":{"type":"string"}},"required":["title","startDate","endDate","reasoning"]}
    """

    private let gateway: EventKitGateway
    private let auditLog: AuditLog
    private let turnIDProvider: @Sendable () -> TurnID
    private let actorRef: ActorRef

    init(
        gateway: EventKitGateway = .shared,
        auditLog: AuditLog = .shared,
        actor: ActorRef = .coordinator,
        turnIDProvider: @escaping @Sendable () -> TurnID = { TurnID.generate() }
    ) {
        self.gateway = gateway
        self.auditLog = auditLog
        self.actorRef = actor
        self.turnIDProvider = turnIDProvider
    }

    func invoke(argsJSON: String) async throws -> String {
        let args: CalendarWriteArgs = try decode(argsJSON)
        let (result, payload) = await gateway.executeCalendarWrite(args)

        // Audit only on success — failed writes are logged elsewhere (the
        // ToolError surfaces the failure to the LLM transcript already).
        if case .ok = result, let payload, let ekID = payload.ekEventID {
            let action = TurnAction(
                turnID: turnIDProvider(),
                toolID: .calendarWrite,
                actor: actorRef,
                reasoning: args.reasoning,
                inverse: .deleteCalendarEvent(
                    ekEventID: ekID,
                    calendarIdentifier: payload.calendarIdentifier
                )
            )
            do {
                _ = try await auditLog.recordAgentAction(
                    action,
                    text: payload.title,
                    source: "tool:calendar.write"
                )
            } catch {
            }
        }
        return try wireOrThrow(result)
    }
}

// MARK: - calendar.modify

actor CalendarModifyTool: LLMTool {
    let id = ToolID.calendarModify.rawValue
    let description = "Modify an existing calendar event by EventKit identifier."
    let jsonSchemaForArgs = """
    {"type":"object","properties":{"ekEventID":{"type":"string"},"patch":{"type":"object"},"reasoning":{"type":"string"}},"required":["ekEventID","patch","reasoning"]}
    """

    private let gateway: EventKitGateway
    private let auditLog: AuditLog
    private let turnIDProvider: @Sendable () -> TurnID
    private let actorRef: ActorRef

    init(
        gateway: EventKitGateway = .shared,
        auditLog: AuditLog = .shared,
        actor: ActorRef = .coordinator,
        turnIDProvider: @escaping @Sendable () -> TurnID = { TurnID.generate() }
    ) {
        self.gateway = gateway
        self.auditLog = auditLog
        self.actorRef = actor
        self.turnIDProvider = turnIDProvider
    }

    func invoke(argsJSON: String) async throws -> String {
        let args: CalendarModifyArgs = try decode(argsJSON)
        let (result, preMod) = await gateway.executeCalendarModify(args)

        if case .ok = result, let preMod {
            let action = TurnAction(
                turnID: turnIDProvider(),
                toolID: .calendarModify,
                actor: actorRef,
                reasoning: args.reasoning,
                inverse: .modifyCalendarEvent(
                    ekEventID: args.ekEventID,
                    restoreTo: preMod
                )
            )
            do {
                _ = try await auditLog.recordAgentAction(action, source: "tool:calendar.modify")
            } catch {
            }
        }
        return try wireOrThrow(result)
    }
}

// MARK: - calendar.delete (full autonomy; audit-logged per spec §11)

actor CalendarDeleteTool: LLMTool {
    let id = ToolID.calendarDelete.rawValue
    let description = "Delete a calendar event. Full agent autonomy; reasoning REQUIRED."
    let jsonSchemaForArgs = """
    {"type":"object","properties":{"ekEventID":{"type":"string"},"reasoning":{"type":"string"}},"required":["ekEventID","reasoning"]}
    """

    private let gateway: EventKitGateway
    private let auditLog: AuditLog
    private let turnIDProvider: @Sendable () -> TurnID
    private let actorRef: ActorRef

    init(
        gateway: EventKitGateway = .shared,
        auditLog: AuditLog = .shared,
        actor: ActorRef = .coordinator,
        turnIDProvider: @escaping @Sendable () -> TurnID = { TurnID.generate() }
    ) {
        self.gateway = gateway
        self.auditLog = auditLog
        self.actorRef = actor
        self.turnIDProvider = turnIDProvider
    }

    func invoke(argsJSON: String) async throws -> String {
        let args: CalendarDeleteArgs = try decode(argsJSON)
        let (result, snapshot) = await gateway.executeCalendarDelete(args)

        if case .ok = result, let snapshot {
            let action = TurnAction(
                turnID: turnIDProvider(),
                toolID: .calendarDelete,
                actor: actorRef,
                reasoning: args.reasoning,
                inverse: .restoreCalendarEvent(payload: snapshot)
            )
            do {
                _ = try await auditLog.recordAgentAction(
                    action,
                    text: snapshot.title,
                    source: "tool:calendar.delete"
                )
            } catch {
            }
        }
        return try wireOrThrow(result)
    }
}

// MARK: - reminder.create

actor ReminderCreateTool: LLMTool {
    let id = ToolID.reminderCreate.rawValue
    let description = "Create a Reminder (EKReminder)."
    let jsonSchemaForArgs = """
    {"type":"object","properties":{"title":{"type":"string"},"dueDate":{"type":"string","format":"date-time"},"notes":{"type":"string"},"listName":{"type":"string"},"reasoning":{"type":"string"}},"required":["title","reasoning"]}
    """

    private let gateway: EventKitGateway
    private let auditLog: AuditLog
    private let turnIDProvider: @Sendable () -> TurnID
    private let actorRef: ActorRef

    init(
        gateway: EventKitGateway = .shared,
        auditLog: AuditLog = .shared,
        actor: ActorRef = .coordinator,
        turnIDProvider: @escaping @Sendable () -> TurnID = { TurnID.generate() }
    ) {
        self.gateway = gateway
        self.auditLog = auditLog
        self.actorRef = actor
        self.turnIDProvider = turnIDProvider
    }

    func invoke(argsJSON: String) async throws -> String {
        let args: ReminderCreateArgs = try decode(argsJSON)
        let (result, payload) = await gateway.executeReminderCreate(args)

        if case .ok = result, let payload, let ekID = payload.ekReminderID {
            let action = TurnAction(
                turnID: turnIDProvider(),
                toolID: .reminderCreate,
                actor: actorRef,
                reasoning: args.reasoning,
                inverse: .deleteReminder(
                    ekReminderID: ekID,
                    listIdentifier: payload.listIdentifier
                )
            )
            do {
                _ = try await auditLog.recordAgentAction(
                    action,
                    text: payload.title,
                    source: "tool:reminder.create"
                )
            } catch {
            }
        }
        return try wireOrThrow(result)
    }
}

// MARK: - reminder.complete

actor ReminderCompleteTool: LLMTool {
    let id = ToolID.reminderComplete.rawValue
    let description = "Mark a Reminder complete."
    let jsonSchemaForArgs = """
    {"type":"object","properties":{"ekReminderID":{"type":"string"},"reasoning":{"type":"string"}},"required":["ekReminderID","reasoning"]}
    """

    private let gateway: EventKitGateway
    private let auditLog: AuditLog
    private let turnIDProvider: @Sendable () -> TurnID
    private let actorRef: ActorRef

    init(
        gateway: EventKitGateway = .shared,
        auditLog: AuditLog = .shared,
        actor: ActorRef = .coordinator,
        turnIDProvider: @escaping @Sendable () -> TurnID = { TurnID.generate() }
    ) {
        self.gateway = gateway
        self.auditLog = auditLog
        self.actorRef = actor
        self.turnIDProvider = turnIDProvider
    }

    func invoke(argsJSON: String) async throws -> String {
        let args: ReminderCompleteArgs = try decode(argsJSON)
        let result = await gateway.executeReminderComplete(args)

        if case .ok = result {
            // Inverse: recreate the reminder. We don't have the pre-complete
            // payload here — completing isn't a delete, just a flag flip — so
            // the inverse stores a payload with just the ID and recreate logic
            // re-fetches at undo time if the reminder still exists.
            let action = TurnAction(
                turnID: turnIDProvider(),
                toolID: .reminderComplete,
                actor: actorRef,
                reasoning: args.reasoning,
                inverse: .recreateReminder(payload: ReminderPayload(
                    title: "",
                    ekReminderID: args.ekReminderID
                ))
            )
            do {
                _ = try await auditLog.recordAgentAction(action, source: "tool:reminder.complete")
            } catch {
            }
        }
        return try wireOrThrow(result)
    }
}

// MARK: - reminder.list (read-only — no audit row)

actor ReminderListTool: LLMTool {
    let id = ToolID.reminderList.rawValue
    let description = "List Reminders."
    let jsonSchemaForArgs = """
    {"type":"object","properties":{"listName":{"type":"string"},"completed":{"type":"boolean"}}}
    """

    private let gateway: EventKitGateway
    init(gateway: EventKitGateway = .shared) { self.gateway = gateway }

    func invoke(argsJSON: String) async throws -> String {
        let args: ReminderListArgs
        if let data = argsJSON.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(ReminderListArgs.self, from: data) {
            args = parsed
        } else {
            args = ReminderListArgs()
        }
        let result = await gateway.executeReminderList(args)
        return try wireOrThrow(result)
    }
}

// MARK: - Shared helpers

private func decode<T: Decodable>(_ json: String) throws -> T {
    guard let data = json.data(using: .utf8) else {
        throw ToolError(kind: .argumentsInvalid, message: "argsJSON not UTF-8")
    }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    do {
        return try dec.decode(T.self, from: data)
    } catch {
        throw ToolError(kind: .argumentsInvalid, message: "\(error)")
    }
}

/// Convert a CalendarToolResult into the LLM-visible wire string, or throw a
/// non-LLM-visible ToolError when the result is `.permissionRequired` (so
/// the UI layer can intercept).
private func wireOrThrow(_ result: CalendarToolResult) throws -> String {
    switch result {
    case .ok(let json):
        return json
    case .permissionRequired(let scope):
        // HARD REJECT #19: never let this enum case reach the model. Tools
        // throw it; the dispatcher (Track B) catches it on the host side and
        // runs the inline-grant flow before retrying the tool call.
        throw PermissionRequiredSignal(scope: scope)
    case .permissionDenied(let scope, let hint):
        // LLM-visible structured tool_error.
        return try encodeStatus("permission_denied", scope: scope, hint: hint)
    case .systemError(let scope, let hint):
        // LLM-visible structured tool_error — distinct status so the model
        // doesn't conflate a transient EventKit save failure with a
        // permission revoke. Encourages "ask user to retry" routing rather
        // than "skip and apologize."
        return try encodeStatus("system_error", scope: scope, hint: hint)
    }
}

private func encodeStatus(_ status: String, scope: EKPermissionScope, hint: String) throws -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let body: [String: String] = [
        "status": status,
        "scope": scope.rawValue,
        "hint": hint
    ]
    let data = try enc.encode(body)
    return String(data: data, encoding: .utf8) ?? "{\"status\":\"\(status)\"}"
}

/// Signal type thrown by EventKit tools when the result is `.permissionRequired`.
/// Track B's dispatcher catches this on the host side BEFORE the result reaches
/// `LanguageModelSession`, runs the inline-grant flow, and retries the tool
/// call once.
struct PermissionRequiredSignal: Error, Sendable {
    let scope: EKPermissionScope
    init(scope: EKPermissionScope) { self.scope = scope }
}
