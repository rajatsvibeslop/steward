//
//  ParseCSVOverrideTests.swift
//  StewardTests
//
//  Each kind's `parseCSVOverride` should:
//   - return [] when data.csv matches state exactly
//   - emit ManualCorrection for differing editable cells
//   - skip render-only cells (totals, percentages)
//
//  Per-kind smoke; thorough cell-by-cell coverage lives in the integration
//  tests for Pod F's CSVMirrorWatcher.
//

import XCTest
@testable import Steward

final class ParseCSVOverrideTests: XCTestCase {

    private let iso = ISO8601DateFormatter()

    private func d(_ s: String) -> Date {
        iso.date(from: s) ?? Date()
    }

    // MARK: - RunningAccumulator

    func test_runningAccumulator_noEdit_returnsEmpty() throws {
        let def = RunningAccumulator.Definition(unit: "min", dailyTarget: 60, weeklyTarget: nil, capturePrompt: "")
        let entries = [
            RunningAccumulator.State.Entry(at: d("2026-05-17T10:00:00Z"), value: 20)
        ]
        let state = RunningAccumulator.State(
            windowEvents: entries, todayTotal: 20, sevenDayAvg: 2.86, thirtyDayAvg: 0.67,
            lastEventAt: entries[0].at
        )
        let table = CSVTable.make(
            kindColumns: ["date", "value", "unit", "today_total", "seven_day_avg", "thirty_day_avg"],
            rows: [[
                "row-1", "1", iso.string(from: entries[0].at),
                iso.string(from: entries[0].at), "20.0", "min", "20.0", "2.86", "0.67"
            ]]
        )
        let corrections = try RunningAccumulator.parseCSVOverride(table, current: state, definition: def)
        XCTAssertTrue(corrections.isEmpty)
    }

    func test_runningAccumulator_valueEdited_emitsCorrection() throws {
        let def = RunningAccumulator.Definition(unit: "min", dailyTarget: nil, weeklyTarget: nil, capturePrompt: "")
        let entries = [
            RunningAccumulator.State.Entry(at: d("2026-05-17T10:00:00Z"), value: 20)
        ]
        let state = RunningAccumulator.State(
            windowEvents: entries, todayTotal: 20, sevenDayAvg: 0, thirtyDayAvg: 0,
            lastEventAt: entries[0].at
        )
        // User changed value from 20 → 25.
        let table = CSVTable.make(
            kindColumns: ["date", "value", "unit", "today_total", "seven_day_avg", "thirty_day_avg"],
            rows: [[
                "row-1", "1", iso.string(from: entries[0].at),
                iso.string(from: entries[0].at), "25.0", "min", "20.0", "0.0", "0.0"
            ]]
        )
        let corrections = try RunningAccumulator.parseCSVOverride(table, current: state, definition: def)
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.cell, "value")
        XCTAssertEqual(corrections.first?.rowID, "row-1")
        XCTAssertEqual(corrections.first?.newValue, "25.0")
    }

    // MARK: - BoundedBudget

    func test_boundedBudget_notesEdit_emitsCorrection() throws {
        let def = BoundedBudget.Definition(unit: "USD", period: .daily, limit: 100, rollover: false)
        let entries = [
            BoundedBudget.State.Entry(at: d("2026-05-17T10:00:00Z"), value: 40, notes: "lunch")
        ]
        let state = BoundedBudget.State(
            periodStartAt: d("2026-05-17T00:00:00Z"), periodTotal: 40, remaining: 60,
            recentEntries: entries, rolloverBalance: 0
        )
        let table = CSVTable.make(
            kindColumns: ["entry_at", "value", "notes", "period_total", "remaining", "rollover_balance"],
            rows: [[
                "entry-1", "1", iso.string(from: entries[0].at),
                iso.string(from: entries[0].at), "40.0", "dinner", "40.0", "60.0", "0.0"
            ]]
        )
        let corrections = try BoundedBudget.parseCSVOverride(table, current: state, definition: def)
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.cell, "notes")
        XCTAssertEqual(corrections.first?.newValue, "dinner")
    }

    // MARK: - Checklist

    func test_checklist_uncheckedToggle_emitsCorrection() throws {
        let def = Checklist.Definition(items: [
            .init(id: "brush", label: "Brush", recurrence: nil)
        ])
        let state = Checklist.State(checkedToday: ["brush"], streakByItem: ["brush": 1], lastResetAt: d("2026-05-17T00:00:00Z"))
        // User unchecked brush in data.csv.
        let table = CSVTable.make(
            kindColumns: ["item_id", "label", "checked", "streak"],
            rows: [["brush", "1", iso.string(from: state.lastResetAt), "brush", "Brush", "false", "1"]]
        )
        let corrections = try Checklist.parseCSVOverride(table, current: state, definition: def)
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.cell, "checked")
        XCTAssertEqual(corrections.first?.oldValue, "true")
        XCTAssertEqual(corrections.first?.newValue, "false")
    }

    func test_checklist_invalidBoolean_throws() {
        let def = Checklist.Definition(items: [.init(id: "brush", label: "Brush", recurrence: nil)])
        let state = Checklist.State(checkedToday: [], streakByItem: ["brush": 0], lastResetAt: Date())
        let table = CSVTable.make(
            kindColumns: ["item_id", "label", "checked", "streak"],
            rows: [["brush", "1", "x", "brush", "Brush", "maybe", "0"]]
        )
        XCTAssertThrowsError(try Checklist.parseCSVOverride(table, current: state, definition: def))
    }

    // MARK: - WeeklyEvidenceLog

    func test_weeklyEvidenceLog_textEdit_emitsCorrection() throws {
        let def = WeeklyEvidenceLog.Definition(prompt: "wins?", weekStartDow: 2)
        let entries = [
            WeeklyEvidenceLog.State.Entry(at: d("2026-05-12T10:00:00Z"), text: "won the bet")
        ]
        let state = WeeklyEvidenceLog.State(
            currentWeekStart: d("2026-05-11T00:00:00Z"),
            currentWeekEntries: entries,
            previousWeeksSummaries: []
        )
        let table = CSVTable.make(
            kindColumns: ["entry_at", "text"],
            rows: [["entry-0", "1", iso.string(from: entries[0].at),
                    iso.string(from: entries[0].at), "won bigger than expected"]]
        )
        let corrections = try WeeklyEvidenceLog.parseCSVOverride(table, current: state, definition: def)
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.cell, "text")
        XCTAssertEqual(corrections.first?.newValue, "won bigger than expected")
    }

    // MARK: - CountdownCommitment

    func test_countdownCommitment_countEdit_emitsCorrection() throws {
        let def = CountdownCommitment.Definition(targetCount: 3, window: .week, successEventKind: "push_back")
        let completed = [
            CountdownCommitment.State.CompletedEvent(eventID: "evt-1", at: d("2026-05-12T10:00:00Z"), notes: "no thanks")
        ]
        let state = CountdownCommitment.State(
            count: 1, target: 3,
            windowStart: d("2026-05-11T00:00:00Z"), windowEnd: d("2026-05-18T00:00:00Z"),
            completedEvents: completed
        )
        let table = CSVTable.make(
            kindColumns: ["completed_at", "notes", "count", "target"],
            rows: [["evt-1", "1", iso.string(from: completed[0].at),
                    iso.string(from: completed[0].at), "no thanks", "5", "3"]]
        )
        let corrections = try CountdownCommitment.parseCSVOverride(table, current: state, definition: def)
        let countCorrections = corrections.filter { $0.cell == "count" }
        XCTAssertEqual(countCorrections.count, 1)
        XCTAssertEqual(countCorrections.first?.newValue, "5")
    }
}
