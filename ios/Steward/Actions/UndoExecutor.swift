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
import GRDB

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
            // the EventKit gateway owns both methods (reopen + create), so the
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

        // ---- DB-only inverse actions (no throws) ----
        //
        // All five below were `notYetImplemented` in earlier passes; the catalog
        // owned the implementation. Each handler:
        //   - performs the inverse via a single `db.write { }` transaction,
        //   - asserts the mutation actually touched a row (no silent no-op),
        //   - appends a `manual_correction` audit event with kind='undo' so
        //     the round-trip is reflected in the events stream the same way
        //     CSV reconciliation surfaces external edits.

        case .archiveDomain(let domain, _):
            // Undo of `domain.archive` — clear archived_at.
            try await updateDomainArchivedAt(domain: domain, archivedAt: nil)

        case .unarchiveDomain(let domain):
            // Undo of `domain.create` (or a prior unarchive) — set archived_at.
            try await updateDomainArchivedAt(domain: domain, archivedAt: Date())

        case .forgetMemory(let memoryID):
            // Undo of `memory.forget` — restore the row to retrievable state.
            // The original memory.forget zeros strength; the inverse clears
            // archived_at AND re-bumps strength so the reranker sees the row
            // again. Using archived_at as the gate keeps the inverse a
            // single column-write that pairs symmetrically with
            // `.unforgetMemory`; strength restoration is the secondary edit
            // that makes the restore actually visible.
            try await setMemoryArchived(memoryID: memoryID, archived: false)

        case .unforgetMemory(let memoryID):
            // Undo of `memory.save` — hide the freshly-admitted row by
            // setting archived_at. MemoryRetriever.retrieve filters
            // `archived_at IS NULL`, so the model stops surfacing it. Row
            // is preserved (no DELETE) so any provenance references survive.
            try await setMemoryArchived(memoryID: memoryID, archived: true)

        // ---- v1.1 patch: remaining 8-tool undo coverage ----
        //
        // Same pattern as the 5 above: single `db.write { }`, assert affected
        // rows so no silent no-op, emit a `manual_correction` audit row.

        case .deleteCommitment(let commitmentID):
            // Undo of `commitment.create` — DELETE the row. Commitments are
            // NOT append-only and have no inbound foreign keys to preserve.
            try await deleteCommitmentRow(commitmentID: commitmentID)

        case .restoreCommitmentStatus(let commitmentID, let priorStatus, let priorDueAt, let priorCompletedAt):
            // Undo of `commitment.complete` / `.abandon` / `.snooze` — replay
            // the captured prior state. Single handler reused across all 3
            // tools because the shape of the change is identical (status
            // ± due_at ± completed_at).
            try await restoreCommitmentStatus(
                commitmentID: commitmentID,
                priorStatus: priorStatus,
                priorDueAt: priorDueAt,
                priorCompletedAt: priorCompletedAt
            )

        case .weakenMemory(let memoryID, let priorStrength, let priorLastStrengthUpdateAt):
            // Undo of `memory.strengthen` — restore the pre-bump strength
            // AND last_strength_update_at so the lazy decay formula picks up
            // where it left off rather than treating the undo time as the
            // anchor.
            try await restoreMemoryStrength(
                memoryID: memoryID,
                priorStrength: priorStrength,
                priorLastStrengthUpdateAt: priorLastStrengthUpdateAt
            )

        case .restoreDomainPrompt(let domain, let priorRolePrompt):
            // Undo of `domain.update_prompt` — write the captured prior
            // role_prompt back.
            try await restoreDomainPrompt(
                domain: domain,
                priorRolePrompt: priorRolePrompt
            )
        }
    }

    // MARK: - DB-mutation handler helpers

    /// Replay every event for `instrumentID` EXCEPT `excludingEventID` from
    /// `K.initialState`, persist the recomputed state, and write a
    /// `manual_correction` audit event so the reversal shows up in history.
    ///
    /// Throws `eventPayloadMissing` if the named event doesn't belong to
    /// this instrument or doesn't exist — silent no-ops would hide bugs.
    private func updateDomainArchivedAt(domain: String, archivedAt: Date?) async throws {
        let queue = try await provider.database()
        try await queue.write { db in
            let archivedMs: Int64? = archivedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
            try db.execute(
                sql: "UPDATE domains SET archived_at = ? WHERE domain = ?",
                arguments: [archivedMs, domain]
            )
            let affected = db.changesCount
            if affected == 0 {
                throw UndoExecutorError.backendFailure(
                    "domain '\(domain)' not found — cannot toggle archived_at"
                )
            }
            let reverseTo = archivedAt == nil ? "unarchived" : "archived"
            try EventLog.append(
                actor: .coordinator,
                kind: "manual_correction",
                text: "domain \(domain) \(reverseTo) by undo",
                domain: domain,
                payloadJSON: "{\"kind\":\"undo\",\"domain\":\"\(domain)\",\"archived\":\(archivedAt == nil ? "false" : "true")}",
                source: "undo",
                reasoning: "reverted action on domain \(domain)",
                at: Date(),
                in: db
            )
        }
    }

    /// Toggle a memory's archived_at. When `archived` is false we ALSO
    /// re-bump strength to 1.0 so the reranker sees the row as fresh —
    /// otherwise `memory.forget`'s strength=0 would keep it permanently
    /// hidden even after clearing the archive flag. Throws on missing row.
    private func setMemoryArchived(memoryID: MemoryID, archived: Bool) async throws {
        let queue = try await provider.database()
        try await queue.write { db in
            let nowDate = Date()
            let nowMs = Int64(nowDate.timeIntervalSince1970 * 1000)
            if archived {
                try db.execute(
                    sql: """
                        UPDATE memory_items
                        SET archived_at = ?
                        WHERE memory_id = ?
                    """,
                    arguments: [nowMs, memoryID]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE memory_items
                        SET archived_at = NULL,
                            strength_at_last_update = 1.0,
                            last_strength_update_at = ?
                        WHERE memory_id = ?
                    """,
                    arguments: [nowMs, memoryID]
                )
            }
            let affected = db.changesCount
            if affected == 0 {
                throw UndoExecutorError.backendFailure(
                    "memory \(memoryID.rawValue) not found — cannot toggle archived_at"
                )
            }
            try EventLog.append(
                actor: .coordinator,
                kind: "manual_correction",
                text: "memory \(memoryID.rawValue) \(archived ? "hidden" : "restored") by undo",
                payloadJSON: "{\"kind\":\"undo\",\"memory_id\":\"\(memoryID.rawValue)\",\"archived\":\(archived)}",
                source: "undo",
                reasoning: "reverted action on memory \(memoryID.rawValue)",
                at: nowDate,
                in: db
            )
        }
    }

    /// Toggle an instrument's `archived_at`. `archivedAt == nil` clears
    /// (unarchive); passing a Date sets (archive). Also bumps
    /// `last_updated_at` so the agent's instrument.list view reflects the
    /// change. Throws on row-not-found.

    /// Restore the captured pre-update definition JSON for an instrument.
    /// Throws on row-not-found.

    /// DELETE a commitment row. Commitments table has no inbound FKs we care
    /// about; ek_reminder_id is the EventKit gateway mirror, undone via its own handlers.
    /// Throws on row-not-found.
    private func deleteCommitmentRow(commitmentID: CommitmentID) async throws {
        let queue = try await provider.database()
        try await queue.write { db in
            let nowDate = Date()
            try db.execute(
                sql: "DELETE FROM commitments WHERE commitment_id = ?",
                arguments: [commitmentID]
            )
            let affected = db.changesCount
            if affected == 0 {
                throw UndoExecutorError.backendFailure(
                    "commitment \(commitmentID.rawValue) not found — cannot delete"
                )
            }
            try EventLog.append(
                actor: .coordinator,
                kind: "manual_correction",
                text: "commitment \(commitmentID.rawValue) deleted by undo",
                commitmentID: commitmentID,
                payloadJSON: "{\"kind\":\"undo\",\"commitment_id\":\"\(commitmentID.rawValue)\",\"deleted\":true}",
                source: "undo",
                reasoning: "reverted commitment.create on \(commitmentID.rawValue)",
                at: nowDate,
                in: db
            )
        }
    }

    /// Restore a commitment's prior status / due_at / completed_at snapshot.
    /// Throws on row-not-found.
    private func restoreCommitmentStatus(
        commitmentID: CommitmentID,
        priorStatus: CommitmentStatus,
        priorDueAt: Date?,
        priorCompletedAt: Date?
    ) async throws {
        let queue = try await provider.database()
        try await queue.write { db in
            let nowDate = Date()
            let dueMs: Int64? = priorDueAt.map { Int64($0.timeIntervalSince1970 * 1000) }
            let completedMs: Int64? = priorCompletedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
            try db.execute(
                sql: """
                    UPDATE commitments
                    SET status = ?, due_at = ?, completed_at = ?
                    WHERE commitment_id = ?
                """,
                arguments: [priorStatus.rawValue, dueMs, completedMs, commitmentID]
            )
            let affected = db.changesCount
            if affected == 0 {
                throw UndoExecutorError.backendFailure(
                    "commitment \(commitmentID.rawValue) not found — cannot restore status"
                )
            }
            try EventLog.append(
                actor: .coordinator,
                kind: "manual_correction",
                text: "commitment \(commitmentID.rawValue) status restored to \(priorStatus.rawValue)",
                commitmentID: commitmentID,
                payloadJSON: "{\"kind\":\"undo\",\"commitment_id\":\"\(commitmentID.rawValue)\",\"prior_status\":\"\(priorStatus.rawValue)\"}",
                source: "undo",
                reasoning: "reverted commitment status transition on \(commitmentID.rawValue)",
                at: nowDate,
                in: db
            )
        }
    }

    /// Restore a memory's pre-strengthen strength + last_strength_update_at.
    /// Throws on row-not-found.
    private func restoreMemoryStrength(
        memoryID: MemoryID,
        priorStrength: Double,
        priorLastStrengthUpdateAt: Date
    ) async throws {
        let queue = try await provider.database()
        try await queue.write { db in
            let nowDate = Date()
            let priorMs = Int64(priorLastStrengthUpdateAt.timeIntervalSince1970 * 1000)
            try db.execute(
                sql: """
                    UPDATE memory_items
                    SET strength_at_last_update = ?, last_strength_update_at = ?
                    WHERE memory_id = ?
                """,
                arguments: [priorStrength, priorMs, memoryID]
            )
            let affected = db.changesCount
            if affected == 0 {
                throw UndoExecutorError.backendFailure(
                    "memory \(memoryID.rawValue) not found — cannot weaken"
                )
            }
            try EventLog.append(
                actor: .coordinator,
                kind: "manual_correction",
                text: "memory \(memoryID.rawValue) strength restored by undo",
                payloadJSON: "{\"kind\":\"undo\",\"memory_id\":\"\(memoryID.rawValue)\",\"prior_strength\":\(priorStrength)}",
                source: "undo",
                reasoning: "reverted memory.strengthen on \(memoryID.rawValue)",
                at: nowDate,
                in: db
            )
        }
    }

    /// Restore a domain's pre-update role_prompt. Throws on row-not-found.
    private func restoreDomainPrompt(
        domain: String,
        priorRolePrompt: String
    ) async throws {
        let queue = try await provider.database()
        try await queue.write { db in
            let nowDate = Date()
            try db.execute(
                sql: "UPDATE domains SET role_prompt = ? WHERE domain = ?",
                arguments: [priorRolePrompt, domain]
            )
            let affected = db.changesCount
            if affected == 0 {
                throw UndoExecutorError.backendFailure(
                    "domain '\(domain)' not found — cannot restore role_prompt"
                )
            }
            try EventLog.append(
                actor: .coordinator,
                kind: "manual_correction",
                text: "domain \(domain) role_prompt restored by undo",
                domain: domain,
                payloadJSON: "{\"kind\":\"undo\",\"domain\":\"\(domain)\"}",
                source: "undo",
                reasoning: "reverted domain.update_prompt on \(domain)",
                at: nowDate,
                in: db
            )
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

