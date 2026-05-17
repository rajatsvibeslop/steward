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

        // ---- Pod C / cross-pod cases (real handlers — no throws) ----
        //
        // All five below were `notYetImplemented` in the Pod B handoff; Pod C
        // owned the implementation. Each handler:
        //   - performs the inverse via a single `db.write { }` transaction,
        //   - asserts the mutation actually touched a row (no silent no-op),
        //   - appends a `manual_correction` audit event with kind='undo' so
        //     the round-trip is reflected in the events stream the same way
        //     CSV reconciliation surfaces external edits.

        case .revertInstrumentEvent(let instrumentIDRaw, let eventIDToReverse):
            try await revertInstrumentEvent(
                instrumentID: InstrumentID(rawValue: instrumentIDRaw),
                excludingEventID: eventIDToReverse
            )

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
        }
    }

    // MARK: - Pod C handler helpers

    /// Replay every event for `instrumentID` EXCEPT `excludingEventID` from
    /// `K.initialState`, persist the recomputed state, and write a
    /// `manual_correction` audit event so the reversal shows up in history.
    ///
    /// Throws `eventPayloadMissing` if the named event doesn't belong to
    /// this instrument or doesn't exist — silent no-ops would hide bugs.
    private func revertInstrumentEvent(
        instrumentID: InstrumentID,
        excludingEventID: EventID
    ) async throws {
        let queue = try await provider.database()
        try await queue.write { db in
            // Load instrument row (kind + definition).
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT kind, definition_json, state_version, created_at, domain
                    FROM instruments WHERE instrument_id = ?
                """,
                arguments: [instrumentID]
            ) else {
                throw UndoExecutorError.backendFailure(
                    "instrument \(instrumentID.rawValue) not found"
                )
            }
            let kind: String = row["kind"]
            let definitionJSON: String = row["definition_json"]
            let createdAtMs: Int64 = row["created_at"]
            let domain: String = row["domain"]
            let createdAt = Date(timeIntervalSince1970: Double(createdAtMs) / 1000)

            // Pull every event in chronological order that targets this
            // instrument and has a `payload_json` (the apply-event tool always
            // populates payload_json with the kind-typed payload).
            let eventRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT event_id, kind, actor, created_at, payload_json, text
                    FROM events
                    WHERE instrument_id = ?
                      AND payload_json IS NOT NULL
                    ORDER BY created_at ASC, event_id ASC
                """,
                arguments: [instrumentID]
            )

            // Verify the named event is in the set we'll be excluding.
            let excludedRaw = excludingEventID.rawValue
            let hasExcluded = eventRows.contains { ($0["event_id"] as String) == excludedRaw }
            if !hasExcluded {
                throw UndoExecutorError.backendFailure(
                    "event \(excludedRaw) not found among instrument \(instrumentID.rawValue) events"
                )
            }

            // Rebuild state from initial, replaying every event except the
            // excluded one. Done as a series of individual UPDATEs through
            // the registry — this is correct because dispatchApply persists
            // state_json each call, so the next iteration reads the updated
            // value. We first reset state_json to the initial state.
            let initialStateJSON = try InstrumentRegistry.initialStateJSON(
                forKind: kind,
                definitionJSON: definitionJSON,
                now: createdAt
            )
            let stateVersion = InstrumentRegistry.currentStateVersion(forKind: kind) ?? 1
            try db.execute(
                sql: """
                    UPDATE instruments
                    SET state_json = ?, state_version = ?, last_updated_at = ?
                    WHERE instrument_id = ?
                """,
                arguments: [
                    initialStateJSON,
                    stateVersion,
                    createdAtMs,
                    instrumentID
                ]
            )

            // The instrument-apply-event tool we want to revert was filed
            // through EventLog.append with kind set to a per-instrument
            // event-kind (e.g. "spend", "log"). Other event rows on the
            // same instrument may be lifecycle events (instrument_create,
            // instrument_archive, etc.) whose payload_json is the definition
            // JSON, NOT a kind-typed payload. Replay only rows whose payload
            // parses cleanly as the kind's event envelope; skip the lifecycle
            // rows. The same heuristic is what InstrumentApplyEventTool used
            // to write them — they're stored as an envelope with a `payload`
            // field. Lifecycle rows have payload_json = definition or null.
            let replayKindsToSkip: Set<String> = [
                "instrument_create",
                "instrument_archive",
                "instrument_update_definition"
            ]
            for evt in eventRows {
                let eid: String = evt["event_id"]
                if eid == excludedRaw { continue }
                let evtKind: String = evt["kind"]
                if replayKindsToSkip.contains(evtKind) { continue }
                guard let payloadJSON: String = evt["payload_json"] else { continue }
                let evtCreatedMs: Int64 = evt["created_at"]
                let evtCreatedAt = Date(timeIntervalSince1970: Double(evtCreatedMs) / 1000)
                let actor: String = evt["actor"]
                let notes: String? = evt["text"]
                let envelopeJSON = try InstrumentTools.makeEventEnvelopeJSON(
                    eventID: EventID(rawValue: eid),
                    instrumentID: instrumentID,
                    kind: evtKind,
                    actor: actor,
                    createdAt: evtCreatedAt,
                    payloadJSON: payloadJSON,
                    notes: notes
                )
                // dispatchApply tolerates lifecycle-shaped payloads by
                // throwing `eventDecodeFailed`; we treat that as a skip so a
                // legacy non-payload-event doesn't crash the replay.
                do {
                    _ = try InstrumentRegistry.dispatchApply(
                        instrumentID: instrumentID,
                        eventJSON: envelopeJSON,
                        in: db,
                        now: evtCreatedAt
                    )
                } catch InstrumentRegistryError.eventDecodeFailed {
                    continue
                }
            }

            // Emit the audit-trail correction event.
            try EventLog.append(
                actor: .coordinator,
                kind: "manual_correction",
                text: "reverted instrument event \(excludedRaw)",
                domain: domain,
                instrumentID: instrumentID,
                payloadJSON: "{\"kind\":\"undo\",\"reverted_event_id\":\"\(excludedRaw)\"}",
                source: "undo",
                reasoning: "reverted action \(excludedRaw)",
                at: Date(),
                in: db
            )
        }
    }

    /// Toggle a domain's archived_at column. `archivedAt == nil` clears
    /// (unarchive); a Date sets (archive). Throws on row-not-found so we
    /// never silently succeed when the domain is gone.
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

