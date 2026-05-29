//
//  TodayViewModel.swift
//  Steward
//
//  Sheet-based Today surface: the most recent rows logged across all
//  active sheets, sorted newest-first. Replaces the v1 instrument-card
//  rendering — Today is now a glance surface over the workbook the
//  agent actually maintains.
//

import Foundation
import GRDB

@MainActor
final class TodayViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    struct DisplayCell: Identifiable, Equatable {
        let id: String          // "<rowID>:<columnName>"
        let columnName: String
        let displayValue: String
    }

    /// One recent-activity row shown on Today.
    struct ActivityRow: Identifiable, Equatable {
        let id: String          // rowID
        let sheetID: SheetID
        let sheetName: String
        let createdAt: Date
        let cells: [DisplayCell]
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var rows: [ActivityRow] = []
    /// True when the workbook has no sheets at all (different from
    /// "sheets exist but no rows yet" — the latter is still .loaded with
    /// rows.isEmpty).
    @Published private(set) var workbookIsEmpty: Bool = false

    /// Max rows shown on Today. Higher numbers are noisier; the user can
    /// drill into a sheet for the full log.
    private let maxRows: Int

    private let provider: DatabaseProvider

    init(provider: DatabaseProvider = .shared, maxRows: Int = 20) {
        self.provider = provider
        self.maxRows = maxRows
    }

    func load() async {
        state = .loading
        do {
            let db = try await provider.database()
            let cap = self.maxRows
            let result: ([ActivityRow], Bool) = try await db.read { dbase -> ([ActivityRow], Bool) in
                let sheets = try WorkbookStore.listSheets(includeArchived: false, in: dbase)
                if sheets.isEmpty {
                    return ([], true)
                }
                let columnsBySheet = Dictionary(
                    uniqueKeysWithValues: try sheets.map {
                        ($0.sheetID, try WorkbookStore.listColumns(sheetID: $0.sheetID, in: dbase))
                    }
                )
                // Pull recent rows for every sheet, then merge + sort.
                var all: [(Sheet, SheetRow)] = []
                for sheet in sheets {
                    let rows = try WorkbookStore.listRows(sheetID: sheet.sheetID, in: dbase)
                    for row in rows { all.append((sheet, row)) }
                }
                let sorted = all
                    .sorted { $0.1.createdAt > $1.1.createdAt }
                    .prefix(cap)
                let displayRows: [ActivityRow] = sorted.map { (sheet, row) in
                    let columns = columnsBySheet[sheet.sheetID] ?? []
                    let cells = columns.map { column in
                        DisplayCell(
                            id: "\(row.rowID.rawValue):\(column.name)",
                            columnName: column.name,
                            displayValue: SheetDetailViewModel.formatCell(
                                row.cells[column.name] ?? .null,
                                kind: column.kind,
                                unit: column.unit
                            )
                        )
                    }
                    return ActivityRow(
                        id: row.rowID.rawValue,
                        sheetID: sheet.sheetID,
                        sheetName: sheet.displayName,
                        createdAt: row.createdAt,
                        cells: cells
                    )
                }
                return (displayRows, false)
            }
            self.rows = result.0
            self.workbookIsEmpty = result.1
            self.state = .loaded
        } catch {
            self.state = .failed(message: String(describing: error))
        }
    }
}
