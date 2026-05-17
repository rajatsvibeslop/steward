//
//  UndoExecutor.swift
//  Steward
//
//  HARD REJECT #4 enforcement point: the `switch inverse` below is exhaustive
//  WITHOUT a `default:` arm. Adding a new InverseAction case forces a compile
//  error here until the handler is written. The executor returns a typed
//  UndoOutcome — non-undoable / not-found / already-undone are first-class
//  outcomes, never `nil`s.
//
//  Each handler is an actor-isolated dispatcher to the relevant backend
//  (EventKitGateway, NotificationScheduler, DB instrument replay, etc.).
//

import Foundation

actor UndoExecutor {
    static let shared = UndoExecutor()

    private let provider: DatabaseProvider
    private let auditLog: AuditLog
    private let gateway: EventKitGateway
    private let scheduler: NotificationScheduler
    private let turnIDProvider: @Sendable () -> TurnID

    init(
        provider: DatabaseProvider = .shared,
        auditLog: AuditLog = .shared,
        gateway: EventKitGateway = .shared,
        scheduler: NotificationScheduler = .shared,
        turnIDProvider: @escaping @Sendable () -> TurnID = { TurnID.generate() }
    ) {
        self.provider = provider
        self.auditLog = auditLog
        self.gateway = gateway
        self.scheduler = scheduler
        self.turnIDProvider = turnIDProvider
    }

    /// Undo the action recorded at `eventID`. Returns:
    /// - `.undone` on success
    /// - `.alreadyUndone` if a prior undo event already references this id
    /// - `.notFound` if no audit row exists
    /// - `.blockedByDependents` if cascades remain (v1: always empty, so this
    ///   never fires unless callers populate cascades)
    func undo(eventID: EventID, undoneBy: ActorRef, reasoning: String) async throws -> UndoOutcome {
        if try await auditLog.hasBeenUndone(eventID: eventID) {
            return .alreadyUndone(originalEventID: eventID)
        }
        guard let action = try await auditLog.loadTurnAction(eventID: eventID) else {
            return .notFound(originalEventID: eventID)
        }
        if !action.cascades.isEmpty {
            return .blockedByDependents(action.cascades)
        }

        try await execute(action.inverse)

        let undoEventID = try await auditLog.recordUndo(
            originalEventID: eventID,
            undoneBy: undoneBy,
            reasoning: reasoning
        )
        return .undone(originalEventID: eventID, undoEventID: undoEventID)
    }

    /// Execute the inverse. Exhaustive switch, no `default:` — adding a case
    /// to `InverseAction` will fail to compile until handled here.
    func execute(_ inverse: InverseAction) async throws {
        switch inverse {

        // ---- Calendar ----

        case .restoreCalendarEvent(let payload):
            // Undo a calendar.delete by re-creating the event. We don't have
            // the original EKEventStore object reference; route through the
            // gateway's write path so permission gating still applies.
            let args = CalendarWriteArgs(
                title: payload.title,
                startDate: payload.startDate,
                endDate: payload.endDate,
                notes: payload.notes,
                location: payload.location,
                isAllDay: payload.isAllDay,
                calendarName: payload.calendarName,
                reasoning: "undo:restore_calendar_event"
            )
            let (result, _) = await gateway.executeCalendarWrite(args)
            try requireOK(result)

        case .deleteCalendarEvent(let ekEventID, _):
            let args = CalendarDeleteArgs(ekEventID: ekEventID, reasoning: "undo:delete_calendar_event")
            let (result, _) = await gateway.executeCalendarDelete(args)
            try requireOK(result)

        case .modifyCalendarEvent(let ekEventID, let restoreTo):
            let patch = CalendarModifyArgs.Patch(
                title: restoreTo.title,
                startDate: restoreTo.startDate,
                endDate: restoreTo.endDate,
                notes: restoreTo.notes,
                location: restoreTo.location,
                isAllDay: restoreTo.isAllDay
            )
            let args = CalendarModifyArgs(
                ekEventID: ekEventID, patch: patch,
                reasoning: "undo:modify_calendar_event"
            )
            let (result, _) = await gateway.executeCalendarModify(args)
            try requireOK(result)

        // ---- Reminders ----

        case .recreateReminder(let payload):
            // Two undo paths converge here:
            //  - undo-of-complete: payload.ekReminderID is set, reminder still
            //    exists in the store; flip `isCompleted` back to false.
            //  - undo-of-delete: payload.ekReminderID is empty/missing;
            //    recreate from the captured payload.
            // Pod D owns both gateway methods (reopen + create), so the
            // executor can run real handlers in v1 — not notYetImplemented.
            if let ekID = payload.ekReminderID, !ekID.isEmpty {
                let result = await gateway.executeReminderReopen(ekReminderID: ekID)
                try requireOK(result)
            } else {
                let args = ReminderCreateArgs(
                    title: payload.title,
                    dueDate: payload.dueDate,
                    notes: payload.notes,
                    listName: payload.listName,
                    reasoning: "undo:recreate_reminder"
                )
                let (result, _) = await gateway.executeReminderCreate(args)
                try requireOK(result)
            }

        case .deleteReminder(let ekReminderID, _):
            // Inverse of reminder.create — route through the gateway's
            // delete path so permission gating still applies.
            let result = await gateway.executeReminderDelete(ekReminderID: ekReminderID)
            try requireOK(result)

        // ---- Notifications ----

        case .rescheduleNotification(let request):
            // Re-schedule using the captured original request. Coordinator
            // scope is the safe default since cancellations only happen from
            // coordinator-driven flows in v1.
            _ = await scheduler.schedule(request, scope: .coordinator)

        case .cancelNotification(let notificationID):
            await scheduler.cancel(id: NotificationID(rawValue: notificationID))

        case .cancelRecurringRule(let ruleID):
            // Undo of `notification.schedule_recurring`: flip the rule's
            // `cancelled_at` AND remove its pending occurrences from UN.
            // Without the rule-flip step, the next `topUpHorizon` (foreground
            // tick + BGAppRefreshTask) would re-issue what the user just
            // undid (deslop regression B).
            await scheduler.cancelRule(ruleID: ruleID)

        // ---- Cross-pod cases (Track C owns the real handlers) ----
        //
        // Per arch's redirect: NOT-YET-IMPLEMENTED uses explicit case +
        // typed throw. NO `default:` arm — the compiler still enforces
        // exhaustiveness, and Pod C's commit swaps these throws for real
        // handlers without touching Track D code.

        case .revertInstrumentEvent:
            throw UndoExecutorError.notYetImplemented(.revertInstrumentEvent)
        case .archiveDomain:
            throw UndoExecutorError.notYetImplemented(.archiveDomain)
        case .unarchiveDomain:
            throw UndoExecutorError.notYetImplemented(.unarchiveDomain)
        case .forgetMemory:
            throw UndoExecutorError.notYetImplemented(.forgetMemory)
        case .unforgetMemory:
            throw UndoExecutorError.notYetImplemented(.unforgetMemory)
        }
    }

    // MARK: - helpers

    private func requireOK(_ result: CalendarToolResult) throws {
        switch result {
        case .ok: return
        case .permissionRequired(let scope):
            throw UndoExecutorError.backendFailure("permission required: \(scope.rawValue)")
        case .permissionDenied(_, let hint):
            throw UndoExecutorError.backendFailure("permission denied: \(hint)")
        case .systemError(_, let hint):
            throw UndoExecutorError.backendFailure("system error: \(hint)")
        }
    }
}

