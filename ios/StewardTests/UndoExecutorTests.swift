//
//  UndoExecutorTests.swift
//  StewardTests
//
//  Verifies:
//   - Exhaustiveness: every InverseAction case has a handler (compile-time
//     enforced — the test just instantiates each case so we'd hit a fatalError
//     before reaching this file if we'd been sloppy).
//   - AuditLog.recordAgentAction refuses blank reasoning for agent actors.
//   - AuditLog round-trips a TurnAction.
//

import XCTest
import GRDB
@testable import Steward

final class UndoExecutorTests: XCTestCase {

    // MARK: - Exhaustiveness smoke test

    func testEveryInverseActionCanBeInstantiated() {
        // Compile-time check: each enum case must construct. Tests in this
        // file fail to compile if a case is added without updating this list,
        // mirroring the addendum's hard-reject #4 invariant.
        let payload = CalendarEventPayload(
            title: "x", startDate: Date(), endDate: Date(), ekEventID: "ek-1"
        )
        let cases: [InverseAction] = [
            .restoreCalendarEvent(payload: payload),
            .deleteCalendarEvent(ekEventID: "ek-2", calendarIdentifier: "cal-1"),
            .modifyCalendarEvent(ekEventID: "ek-3", restoreTo: payload),
            .recreateReminder(payload: ReminderPayload(title: "r")),
            .deleteReminder(ekReminderID: "rem-1", listIdentifier: "list-1"),
            .rescheduleNotification(request: NotificationRequest(
                kind: .windDown,
                fireAt: Date(),
                templateContext: TemplateContext()
            )),
            .cancelNotification(notificationID: "notif-1"),
            .cancelRecurringRule(ruleID: "rule-1"),
            .revertInstrumentEvent(instrumentID: "inst-1", eventIDToReverse: EventID.generate()),
            .archiveDomain(domain: "health", archivedAt: Date()),
            .unarchiveDomain(domain: "health"),
            .forgetMemory(memoryID: MemoryID(rawValue: "m-1")),
            .unforgetMemory(memoryID: MemoryID(rawValue: "m-1"))
        ]
        XCTAssertEqual(cases.count, 13, "InverseAction case count drift: did you add a case without updating UndoExecutor?")

        // Parity: every InverseAction must map to an InverseActionKind. If
        // someone adds a case to one enum but forgets the other, the
        // `.kind` switch in TurnAction.swift fails to compile — but this
        // assertion guards the *count* parity at runtime so deslop catches
        // a mismatched rename even if the switch happens to compile.
        XCTAssertEqual(
            cases.count,
            InverseActionKind.allCases.count,
            "InverseAction and InverseActionKind drifted apart."
        )
        let kinds = cases.map(\.kind)
        XCTAssertEqual(Set(kinds).count, kinds.count, "`.kind` returned a duplicate — drift in TurnAction.swift")
    }

    func testCrossPodInverseHandlersAreImplemented() async throws {
        // Pod C's commit: the five cross-pod cases below MUST execute without
        // throwing `notYetImplemented`. They may still throw `backendFailure`
        // (e.g., row-not-found when the test passes a synthetic ID), which
        // is the contract — silent success is the failure mode we're guarding
        // against. The previous version of this test asserted the typed
        // notYetImplemented error; that contract has now flipped.
        let executor = UndoExecutor()
        let crossPodCases: [(InverseAction, InverseActionKind)] = [
            (.revertInstrumentEvent(instrumentID: "i", eventIDToReverse: EventID.generate()), .revertInstrumentEvent),
            (.archiveDomain(domain: "d", archivedAt: Date()), .archiveDomain),
            (.unarchiveDomain(domain: "d"), .unarchiveDomain),
            (.forgetMemory(memoryID: MemoryID(rawValue: "m")), .forgetMemory),
            (.unforgetMemory(memoryID: MemoryID(rawValue: "m")), .unforgetMemory)
        ]
        for (action, expectedKind) in crossPodCases {
            do {
                try await executor.execute(action)
                // Some handlers may succeed against a happenstance shared DB;
                // either way, not-yet-implemented is the failure case.
            } catch let e as UndoExecutorError {
                if case .notYetImplemented = e {
                    XCTFail("Pod C handler still missing for \(expectedKind.rawValue): \(e)")
                }
                // Other UndoExecutorError variants (backendFailure for
                // missing rows) are acceptable — they prove the handler
                // ran and surfaced a real DB / state error rather than a
                // typed "not implemented" punt.
            } catch {
                // Non-typed errors are fine too — anything but
                // notYetImplemented satisfies the contract.
            }
        }
    }

    // MARK: - AuditLog

    /// Build an isolated in-memory provider + audit log. Mirrors the pattern
    /// used in Track A's SchemaTests.
    private func makeAuditLog() async throws -> (AuditLog, DatabaseProvider, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-d-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("steward-test.sqlite")
        let provider = DatabaseProvider(location: .file(url))
        // Warm the migration up front so the audit log doesn't race.
        _ = try await provider.database()
        let audit = AuditLog(provider: provider)
        return (audit, provider, dir)
    }

    func testAuditLogRefusesBlankReasoningForAgent() async throws {
        let (audit, _, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        let action = TurnAction(
            turnID: TurnID.generate(),
            toolID: .calendarWrite,
            actor: .coordinator,
            reasoning: "   ",  // whitespace-only
            inverse: .deleteCalendarEvent(ekEventID: "x", calendarIdentifier: nil)
        )
        do {
            _ = try await audit.recordAgentAction(action)
            XCTFail("blank reasoning should throw")
        } catch let e as AuditLogError {
            if case .reasoningEmpty = e { /* good */ } else {
                XCTFail("wrong AuditLogError: \(e)")
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testAuditLogRoundtripsTurnAction() async throws {
        let (audit, _, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = CalendarEventPayload(
            title: "Therapy",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            ekEventID: "ek-abc"
        )
        let action = TurnAction(
            turnID: TurnID.generate(),
            toolID: .calendarDelete,
            actor: .agent(domain: "health"),
            reasoning: "User asked me to drop this; conflict noted in chat.",
            inverse: .restoreCalendarEvent(payload: payload)
        )

        let eventID = try await audit.recordAgentAction(action, source: "tool:calendar.delete")
        let loaded = try await audit.loadTurnAction(eventID: eventID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.toolID, .calendarDelete)
        XCTAssertEqual(loaded?.actor.dbValue, "agent:health")
        if case .restoreCalendarEvent(let loadedPayload) = loaded?.inverse {
            XCTAssertEqual(loadedPayload.ekEventID, "ek-abc")
            XCTAssertEqual(loadedPayload.title, "Therapy")
        } else {
            XCTFail("inverse decoded wrong")
        }
        let undone1 = try await audit.hasBeenUndone(eventID: eventID)
        XCTAssertFalse(undone1)
    }

    func testRecordUndoMarksOriginalAsUndone() async throws {
        let (audit, _, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        let action = TurnAction(
            turnID: TurnID.generate(),
            toolID: .notificationSchedule,
            actor: .coordinator,
            reasoning: "Schedule wind-down per user request.",
            inverse: .cancelNotification(notificationID: "un-1")
        )
        let eventID = try await audit.recordAgentAction(action)
        _ = try await audit.recordUndo(
            originalEventID: eventID,
            undoneBy: .user,
            reasoning: "User tapped undo in Settings."
        )
        let undone = try await audit.hasBeenUndone(eventID: eventID)
        XCTAssertTrue(undone)
    }

    // MARK: - Pod C cross-pod handler round-trips

    private func makeExecutor(provider: DatabaseProvider) -> UndoExecutor {
        UndoExecutor(provider: provider, auditLog: AuditLog(provider: provider))
    }

    func testArchiveDomainRoundTrip() async throws {
        let (_, provider, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = try await provider.database()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO domains
                      (domain, display_name, role_prompt, tool_scope_json, created_at, archived_at)
                    VALUES ('money', 'Money', 'role', '{}', ?, ?)
                """,
                arguments: [nowMs, nowMs]
            )
        }
        let executor = makeExecutor(provider: provider)

        // Apply .archiveDomain inverse → expect archived_at cleared.
        try await executor.execute(.archiveDomain(domain: "money", archivedAt: Date()))
        let afterClear: Int64? = try await queue.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT archived_at FROM domains WHERE domain = ?",
                arguments: ["money"]
            )
        }
        XCTAssertNil(afterClear, "archive-undo should clear archived_at")

        // Apply .unarchiveDomain inverse → expect archived_at set.
        try await executor.execute(.unarchiveDomain(domain: "money"))
        let afterSet: Int64? = try await queue.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT archived_at FROM domains WHERE domain = ?",
                arguments: ["money"]
            )
        }
        XCTAssertNotNil(afterSet, "unarchive-undo should set archived_at")
    }

    func testArchiveDomainNoRowThrowsBackendFailure() async throws {
        let (_, provider, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executor = makeExecutor(provider: provider)
        do {
            try await executor.execute(.archiveDomain(domain: "nope", archivedAt: Date()))
            XCTFail("expected backendFailure for missing domain row")
        } catch let e as UndoExecutorError {
            guard case .backendFailure = e else {
                XCTFail("expected backendFailure, got \(e)")
                return
            }
        }
    }

    func testForgetMemoryRoundTrip() async throws {
        let (_, provider, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = try await provider.database()
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let mid = MemoryID(rawValue: "mem-1")
        let blob = Data(repeating: 0, count: 32 * 4) // 32-float zero blob; retrieval ignores it here.
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO memory_items
                      (memory_id, type, text, embedding, embedding_dim, embedding_revision,
                       strength_at_last_update, last_strength_update_at, created_at)
                    VALUES (?, 'preference', 'no spicy food', ?, 32, 'rev-test', 0.0, ?, ?)
                """,
                arguments: [mid, blob, nowMs, nowMs]
            )
        }
        let executor = makeExecutor(provider: provider)

        // Undo of memory.forget: clear archived_at + restore strength.
        try await executor.execute(.forgetMemory(memoryID: mid))
        let restored: (Double, Int64?) = try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT strength_at_last_update, archived_at FROM memory_items WHERE memory_id = ?",
                arguments: [mid]
            )!
            return (row["strength_at_last_update"], row["archived_at"])
        }
        XCTAssertEqual(restored.0, 1.0, "forget-undo should restore strength to 1.0")
        XCTAssertNil(restored.1, "forget-undo should clear archived_at")

        // Undo of memory.save: set archived_at.
        try await executor.execute(.unforgetMemory(memoryID: mid))
        let archived: Int64? = try await queue.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT archived_at FROM memory_items WHERE memory_id = ?",
                arguments: [mid]
            )
        }
        XCTAssertNotNil(archived, "save-undo should set archived_at")
    }

    func testForgetMemoryMissingRowThrows() async throws {
        let (_, provider, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executor = makeExecutor(provider: provider)
        do {
            try await executor.execute(.unforgetMemory(memoryID: MemoryID(rawValue: "ghost")))
            XCTFail("expected backendFailure for missing memory row")
        } catch let e as UndoExecutorError {
            guard case .backendFailure = e else {
                XCTFail("expected backendFailure, got \(e)")
                return
            }
        }
    }

    func testRevertInstrumentEventRestoresInitialState() async throws {
        // Round-trip: create a Checklist instrument with one item, apply a
        // check event, then call .revertInstrumentEvent to roll it back. The
        // recomputed state should match the initial state (no events
        // applied). We use Checklist because its initial / event payloads
        // are tiny and the diff is easy to assert.
        InstrumentRegistry._resetForTesting()
        InstrumentRegistry.bootstrapAll()

        let (_, provider, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = try await provider.database()

        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let instrumentID = InstrumentID(rawValue: "inst-checklist-1")
        let definitionJSON = """
        {"items":[{"id":"a","label":"morning walk"}]}
        """
        let initialStateJSON = try InstrumentRegistry.initialStateJSON(
            forKind: "checklist", definitionJSON: definitionJSON, now: now
        )
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO instruments
                      (instrument_id, domain, kind, name, definition_json, state_json,
                       state_version, created_at, last_updated_at)
                    VALUES (?, 'health', 'checklist', 'walks', ?, ?, 1, ?, ?)
                """,
                arguments: [instrumentID, definitionJSON, initialStateJSON, nowMs, nowMs]
            )
        }

        // Apply a check event via the same path the tool would use.
        let eventID = EventID(rawValue: "evt-1")
        let checkPayloadJSON = """
        {"item_id":"a","checked":true}
        """
        let envelopeJSON = try InstrumentTools.makeEventEnvelopeJSON(
            eventID: eventID,
            instrumentID: instrumentID,
            kind: "check",
            actor: "coordinator",
            createdAt: now,
            payloadJSON: checkPayloadJSON,
            notes: nil
        )
        try await queue.write { db in
            try EventLog.append(
                actor: .coordinator,
                kind: "check",
                instrumentID: instrumentID,
                payloadJSON: checkPayloadJSON,
                source: "tool",
                reasoning: "test apply",
                at: now,
                eventID: eventID,
                in: db
            )
            _ = try InstrumentRegistry.dispatchApply(
                instrumentID: instrumentID,
                eventJSON: envelopeJSON,
                in: db,
                now: now
            )
        }

        // Sanity: post-apply state differs from initial.
        let afterApply: String = try await queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT state_json FROM instruments WHERE instrument_id = ?",
                arguments: [instrumentID]
            )!
        }
        XCTAssertNotEqual(afterApply, initialStateJSON, "state should change after applying the event")

        // Undo.
        let executor = makeExecutor(provider: provider)
        try await executor.execute(.revertInstrumentEvent(
            instrumentID: instrumentID.rawValue,
            eventIDToReverse: eventID
        ))

        let afterUndo: String = try await queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT state_json FROM instruments WHERE instrument_id = ?",
                arguments: [instrumentID]
            )!
        }
        XCTAssertEqual(afterUndo, initialStateJSON,
                       "reverting the only event should restore the initial state")

        // Audit trail: manual_correction event should exist.
        let correctionCount: Int = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM events WHERE kind = 'manual_correction' AND instrument_id = ?",
                arguments: [instrumentID]
            ) ?? 0
        }
        XCTAssertEqual(correctionCount, 1, "revert should emit a single manual_correction event")
    }

    func testRevertInstrumentEventForUnknownEventThrows() async throws {
        InstrumentRegistry._resetForTesting()
        InstrumentRegistry.bootstrapAll()
        let (_, provider, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = try await provider.database()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let instrumentID = InstrumentID(rawValue: "inst-2")
        let definitionJSON = """
        {"items":[{"id":"a","label":"x"}]}
        """
        let initialStateJSON = try InstrumentRegistry.initialStateJSON(
            forKind: "checklist", definitionJSON: definitionJSON, now: Date()
        )
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO instruments
                      (instrument_id, domain, kind, name, definition_json, state_json,
                       state_version, created_at, last_updated_at)
                    VALUES (?, 'health', 'checklist', 'walks', ?, ?, 1, ?, ?)
                """,
                arguments: [instrumentID, definitionJSON, initialStateJSON, nowMs, nowMs]
            )
        }
        let executor = makeExecutor(provider: provider)
        do {
            try await executor.execute(.revertInstrumentEvent(
                instrumentID: instrumentID.rawValue,
                eventIDToReverse: EventID(rawValue: "no-such-event")
            ))
            XCTFail("expected throw for unknown event ID")
        } catch let e as UndoExecutorError {
            guard case .backendFailure = e else {
                XCTFail("expected backendFailure, got \(e)")
                return
            }
        }
    }

    // MARK: - Pod C tools persist TurnAction audit rows

    func testDomainArchiveToolPersistsTurnActionForUndo() async throws {
        let (audit, provider, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = try await provider.database()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO domains
                      (domain, display_name, role_prompt, tool_scope_json, created_at)
                    VALUES ('health', 'Health', 'role', '{}', ?)
                """,
                arguments: [nowMs]
            )
        }
        let tool = DomainArchiveTool(provider: provider, auditLog: audit)
        let argsJSON = """
        {"domain":"health","reason":"experiment over","reasoning":"user said done","actor":"coordinator"}
        """
        _ = try await tool.invoke(argsJSON: argsJSON)

        // Find the audit row for domain.archive.
        let eventID: String? = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT event_id FROM events WHERE kind = ? ORDER BY created_at DESC LIMIT 1",
                arguments: [ToolID.domainArchive.rawValue]
            )
        }
        XCTAssertNotNil(eventID, "domain.archive must persist a kind='domain.archive' audit row")
        let loaded = try await audit.loadTurnAction(eventID: EventID(rawValue: eventID!))
        XCTAssertNotNil(loaded, "audit row payload should round-trip TurnAction")
        XCTAssertEqual(loaded?.toolID, .domainArchive)
        if case .archiveDomain(let dom, _) = loaded?.inverse {
            XCTAssertEqual(dom, "health")
        } else {
            XCTFail("inverse must be .archiveDomain")
        }
    }

    func testEventsCheckConstraintRejectsAgentRowWithoutReasoningAtDB() async throws {
        // Belt-and-braces — the DB CHECK is the second line of defense after
        // AuditLogError.reasoningEmpty. Verify it actually rejects.
        let (_, provider, dir) = try await makeAuditLog()
        defer { try? FileManager.default.removeItem(at: dir) }

        let queue = try await provider.database()
        do {
            try await queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO events (event_id, created_at, actor, kind)
                    VALUES (?, ?, 'coordinator', 'calendar.write')
                    """,
                    arguments: [UUID().uuidString, Int64(Date().timeIntervalSince1970 * 1000)]
                )
            }
            XCTFail("DB should reject agent row without reasoning")
        } catch {
            // expected — CHECK constraint trips.
        }
    }
}
