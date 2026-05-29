//
//  SheetToolsTests.swift
//  StewardTests
//
//  End-to-end coverage for the seven sheet tools: each test exercises
//  the LLMTool boundary (argsJSON -> resultJSON), then verifies both
//  the workbook storage AND the audit-log entry that should have
//  landed in the events table. WorkbookStoreTests already covers the
//  storage layer in isolation; this file covers the tool-level
//  composition: arg parsing, audit emission, payload shape, and
//  failure surfaces.
//

import XCTest
import GRDB
@testable import Steward

final class SheetToolsTests: XCTestCase {

    // MARK: - Test helpers

    /// Builds a freshly-migrated DatabaseProvider against a unique temp
    /// file. Each test gets its own DB so tool-side audit writes don't
    /// bleed between cases.
    private func makeProvider() async throws -> DatabaseProvider {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheet-tools-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("steward.sqlite")
        let provider = DatabaseProvider(location: .file(url))
        _ = try await provider.database()
        return provider
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Returns the most recent event row of the given kind (or nil).
    private func latestEvent(kind: String, provider: DatabaseProvider) async throws -> Row? {
        let db = try await provider.database()
        return try await db.read { dbase in
            try Row.fetchOne(
                dbase,
                sql: """
                    SELECT * FROM events
                    WHERE kind = ?
                    ORDER BY created_at DESC
                    LIMIT 1
                """,
                arguments: [kind]
            )
        }
    }

    // MARK: - sheet.create

    func test_sheetCreate_persistsSheetColumnsAndEmitsAuditEvent() async throws {
        let provider = try await makeProvider()
        let now = referenceDate
        let tool = SheetCreateTool(provider: provider, now: { now })

        let args = SheetCreateArgs(
            displayName: "Time",
            description: "productive hours",
            columns: [
                SheetCreateColumnSpec(name: "date", kind: .date, unit: nil),
                SheetCreateColumnSpec(name: "minutes", kind: .duration, unit: "min"),
            ],
            reasoning: "user asked to start tracking time",
            actor: "coordinator"
        )
        let resultJSON = try await tool.invoke(argsJSON: try ToolJSON.encode(args))
        let result = try ToolJSON.decode(SheetCreateResult.self, from: resultJSON)
        XCTAssertFalse(result.sheetID.rawValue.isEmpty)
        XCTAssertEqual(result.columnIDs.count, 2)

        // Storage assertions
        let db = try await provider.database()
        let (sheet, columns) = try await db.read { dbase -> (Sheet?, [SheetColumn]) in
            let s = try WorkbookStore.loadSheet(sheetID: result.sheetID, in: dbase)
            let c = try WorkbookStore.listColumns(sheetID: result.sheetID, in: dbase)
            return (s, c)
        }
        XCTAssertEqual(sheet?.displayName, "Time")
        XCTAssertEqual(columns.map(\.name), ["date", "minutes"])
        XCTAssertEqual(columns.map(\.kind), [.date, .duration])
        XCTAssertEqual(columns[1].unit, "min")

        // Audit assertions
        let event = try await latestEvent(kind: "sheet_create", provider: provider)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?["actor"] as String?, "coordinator")
        XCTAssertEqual(event?["text"] as String?, "Time")
        XCTAssertEqual(event?["reasoning"] as String?, "user asked to start tracking time")
        let payload = event?["payload_json"] as String? ?? ""
        XCTAssertTrue(payload.contains(result.sheetID.rawValue))
        XCTAssertTrue(payload.contains("Time"))
    }

    // MARK: - sheet.add_column

    func test_sheetAddColumn_extendsSchemaAndEmitsAuditEvent() async throws {
        let provider = try await makeProvider()
        let now = referenceDate
        let createTool = SheetCreateTool(provider: provider, now: { now })
        let createResultJSON = try await createTool.invoke(argsJSON: try ToolJSON.encode(
            SheetCreateArgs(
                displayName: "Time",
                description: nil,
                columns: [SheetCreateColumnSpec(name: "date", kind: .date, unit: nil)],
                reasoning: "init",
                actor: "coordinator"
            )
        ))
        let sheetID = try ToolJSON.decode(SheetCreateResult.self, from: createResultJSON).sheetID

        let addColumnTool = SheetAddColumnTool(provider: provider, now: { now })
        let addJSON = try await addColumnTool.invoke(argsJSON: try ToolJSON.encode(
            SheetAddColumnArgs(
                sheetID: sheetID,
                name: "minutes",
                kind: .duration,
                unit: "min",
                reasoning: "need a duration column",
                actor: "coordinator"
            )
        ))
        let addResult = try ToolJSON.decode(SheetAddColumnResult.self, from: addJSON)
        XCTAssertFalse(addResult.columnID.rawValue.isEmpty)

        let db = try await provider.database()
        let columns = try await db.read { try WorkbookStore.listColumns(sheetID: sheetID, in: $0) }
        XCTAssertEqual(columns.map(\.name), ["date", "minutes"])
        XCTAssertEqual(columns.map(\.ordinal), [0, 1])

        let event = try await latestEvent(kind: "sheet_add_column", provider: provider)
        XCTAssertEqual(event?["text"] as String?, "minutes")
        let payload = event?["payload_json"] as String? ?? ""
        XCTAssertTrue(payload.contains(sheetID.rawValue))
        XCTAssertTrue(payload.contains("minutes"))
    }

    // MARK: - sheet.add_row (happy + failure)

    func test_sheetAddRow_writesRowAndAuditEvent_withValidCells() async throws {
        let provider = try await makeProvider()
        let now = referenceDate
        let sheetID = try await seedTimeSheet(provider: provider, now: now)

        let addRowTool = SheetAddRowTool(provider: provider, now: { now })
        let resultJSON = try await addRowTool.invoke(argsJSON: try ToolJSON.encode(
            SheetAddRowArgs(
                sheetID: sheetID,
                cells: [
                    "date": .string("2026-05-26"),
                    "minutes": .number(40),
                ],
                reasoning: "user logged a productive session",
                actor: "coordinator"
            )
        ))
        let result = try ToolJSON.decode(SheetAddRowResult.self, from: resultJSON)
        XCTAssertFalse(result.rowID.rawValue.isEmpty)

        let db = try await provider.database()
        let rows = try await db.read { try WorkbookStore.listRows(sheetID: sheetID, in: $0) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].cells["date"], .string("2026-05-26"))
        XCTAssertEqual(rows[0].cells["minutes"], .number(40))

        let event = try await latestEvent(kind: "sheet_add_row", provider: provider)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?["actor"] as String?, "coordinator")
        XCTAssertEqual(event?["reasoning"] as String?, "user logged a productive session")
    }

    func test_sheetAddRow_rejectsUnknownColumn_andSkipsAuditEvent() async throws {
        let provider = try await makeProvider()
        let now = referenceDate
        let sheetID = try await seedTimeSheet(provider: provider, now: now)

        let addRowTool = SheetAddRowTool(provider: provider, now: { now })
        do {
            _ = try await addRowTool.invoke(argsJSON: try ToolJSON.encode(
                SheetAddRowArgs(
                    sheetID: sheetID,
                    cells: ["nonexistent": .number(1)],
                    reasoning: "x",
                    actor: "coordinator"
                )
            ))
            XCTFail("expected unknown-column rejection")
        } catch {
            // expected
        }

        // No row should have been inserted, and no event should have landed.
        let db = try await provider.database()
        let rows = try await db.read { try WorkbookStore.listRows(sheetID: sheetID, in: $0) }
        XCTAssertEqual(rows.count, 0)
        let event = try await latestEvent(kind: "sheet_add_row", provider: provider)
        XCTAssertNil(event, "failed write must not emit an audit event")
    }

    // MARK: - sheet.update_cell

    func test_sheetUpdateCell_updatesValueAndEmitsAuditEvent() async throws {
        let provider = try await makeProvider()
        let now = referenceDate
        let sheetID = try await seedTimeSheet(provider: provider, now: now)

        let addRowTool = SheetAddRowTool(provider: provider, now: { now })
        let addRowJSON = try await addRowTool.invoke(argsJSON: try ToolJSON.encode(
            SheetAddRowArgs(
                sheetID: sheetID,
                cells: ["date": .string("2026-05-26"), "minutes": .number(40)],
                reasoning: "init row",
                actor: "coordinator"
            )
        ))
        let rowID = try ToolJSON.decode(SheetAddRowResult.self, from: addRowJSON).rowID

        let updateTool = SheetUpdateCellTool(provider: provider, now: { now })
        _ = try await updateTool.invoke(argsJSON: try ToolJSON.encode(
            SheetUpdateCellArgs(
                rowID: rowID,
                columnName: "minutes",
                value: .number(60),
                reasoning: "correcting earlier estimate",
                actor: "coordinator"
            )
        ))
        let db = try await provider.database()
        let rows = try await db.read { try WorkbookStore.listRows(sheetID: sheetID, in: $0) }
        XCTAssertEqual(rows[0].cells["minutes"], .number(60))

        let event = try await latestEvent(kind: "sheet_update_cell", provider: provider)
        XCTAssertEqual(event?["reasoning"] as String?, "correcting earlier estimate")
        let payload = event?["payload_json"] as String? ?? ""
        XCTAssertTrue(payload.contains(rowID.rawValue))
        XCTAssertTrue(payload.contains("minutes"))
    }

    // MARK: - sheet.read

    func test_sheetRead_returnsSheetColumnsAndRows() async throws {
        let provider = try await makeProvider()
        let now = referenceDate
        let sheetID = try await seedTimeSheet(provider: provider, now: now)

        // Seed one row via the tool surface.
        _ = try await SheetAddRowTool(provider: provider, now: { now }).invoke(
            argsJSON: try ToolJSON.encode(SheetAddRowArgs(
                sheetID: sheetID,
                cells: ["date": .string("2026-05-26"), "minutes": .number(40)],
                reasoning: "seed",
                actor: "coordinator"
            ))
        )

        let readTool = SheetReadTool(provider: provider)
        let resultJSON = try await readTool.invoke(argsJSON: try ToolJSON.encode(
            SheetReadArgs(sheetID: sheetID)
        ))
        let result = try ToolJSON.decode(SheetReadResult.self, from: resultJSON)
        XCTAssertEqual(result.sheet.displayName, "Time")
        XCTAssertEqual(result.columns.map(\.name), ["date", "minutes"])
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].cells["minutes"], .number(40))
    }

    func test_sheetRead_unknownSheet_throws() async throws {
        let provider = try await makeProvider()
        let readTool = SheetReadTool(provider: provider)
        do {
            _ = try await readTool.invoke(argsJSON: try ToolJSON.encode(
                SheetReadArgs(sheetID: SheetID(rawValue: "doesnotexist"))
            ))
            XCTFail("expected sheet-not-found")
        } catch let validation as SheetValidationError {
            if case .sheetNotFound = validation { /* ok */ }
            else { XCTFail("wrong validation: \(validation)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - sheet.list

    func test_sheetList_excludesArchivedByDefault_includesWithFlag() async throws {
        let provider = try await makeProvider()
        let now = referenceDate
        let activeID = try await seedTimeSheet(provider: provider, now: now)
        // Seed a second sheet and archive it via the archive tool.
        let createTool = SheetCreateTool(provider: provider, now: { now })
        let archivedJSON = try await createTool.invoke(argsJSON: try ToolJSON.encode(
            SheetCreateArgs(
                displayName: "Money",
                description: nil,
                columns: [SheetCreateColumnSpec(name: "amount", kind: .currency, unit: "$")],
                reasoning: "init",
                actor: "coordinator"
            )
        ))
        let archivedID = try ToolJSON.decode(SheetCreateResult.self, from: archivedJSON).sheetID
        _ = try await SheetArchiveTool(provider: provider, now: { now }).invoke(
            argsJSON: try ToolJSON.encode(SheetArchiveArgs(
                sheetID: archivedID,
                reason: "test cleanup",
                reasoning: "no longer needed",
                actor: "coordinator"
            ))
        )

        let listTool = SheetListTool(provider: provider)
        // default — excludes archived
        let activeJSON = try await listTool.invoke(argsJSON: "{}")
        let activeResult = try ToolJSON.decode(SheetListResult.self, from: activeJSON)
        XCTAssertEqual(activeResult.sheets.map(\.sheetID), [activeID])

        let allJSON = try await listTool.invoke(argsJSON: #"{"include_archived":true}"#)
        let allResult = try ToolJSON.decode(SheetListResult.self, from: allJSON)
        XCTAssertEqual(allResult.sheets.count, 2)
    }

    // MARK: - sheet.archive

    func test_sheetArchive_setsArchivedAtAndEmitsAuditEvent() async throws {
        let provider = try await makeProvider()
        let now = referenceDate
        let sheetID = try await seedTimeSheet(provider: provider, now: now)

        let archiveTool = SheetArchiveTool(provider: provider, now: { now.addingTimeInterval(60) })
        _ = try await archiveTool.invoke(argsJSON: try ToolJSON.encode(
            SheetArchiveArgs(
                sheetID: sheetID,
                reason: "merged into another sheet",
                reasoning: "consolidating tracking",
                actor: "coordinator"
            )
        ))
        let db = try await provider.database()
        let sheet = try await db.read { try WorkbookStore.loadSheet(sheetID: sheetID, in: $0) }
        XCTAssertNotNil(sheet?.archivedAt)

        let event = try await latestEvent(kind: "sheet_archive", provider: provider)
        XCTAssertEqual(event?["text"] as String?, "merged into another sheet")
        XCTAssertEqual(event?["reasoning"] as String?, "consolidating tracking")
    }

    // MARK: - Shared fixture

    /// Creates a Time sheet with date + duration columns via the actual
    /// SheetCreateTool, so every test that needs a populated sheet
    /// exercises the full tool path (including the audit event).
    private func seedTimeSheet(provider: DatabaseProvider, now: Date) async throws -> SheetID {
        let createTool = SheetCreateTool(provider: provider, now: { now })
        let json = try await createTool.invoke(argsJSON: try ToolJSON.encode(
            SheetCreateArgs(
                displayName: "Time",
                description: nil,
                columns: [
                    SheetCreateColumnSpec(name: "date", kind: .date, unit: nil),
                    SheetCreateColumnSpec(name: "minutes", kind: .duration, unit: "min"),
                ],
                reasoning: "seed",
                actor: "coordinator"
            )
        ))
        return try ToolJSON.decode(SheetCreateResult.self, from: json).sheetID
    }
}
