//
//  CSVTable.swift
//  Steward — Track F
//
//  Track F operates on the canonical `CSVTable` value type defined by Pod C
//  (`ios/Steward/Instruments/InstrumentKind.swift`). We do NOT redeclare it
//  here — that would re-introduce the duplicate-type compile error that the
//  Pod-F-pre-merge work used a separate struct for.
//
//  This file ADDS what Pod C's `CSVTable` doesn't have: an RFC-4180-ish
//  parser/serializer (Pod C only constructs tables in-memory; the disk
//  round-trip lives here) and `__row_id` partitioning. Both are extensions
//  on `CSVTable` so callers see one type.
//

import Foundation

/// Reserved column names. Pod C's `CSVTable.make(kindColumns:rows:)`
/// auto-prepends `__row_id`, `__steward_version`, `__last_synced_at` in
/// that order; these constants let us look them up by name without
/// peppering string literals across the watcher.
enum CSVReserved {
    static let rowID = "__row_id"
    static let stewardVersion = "__steward_version"
    static let lastSyncedAt = "__last_synced_at"
    static let all: Set<String> = [rowID, stewardVersion, lastSyncedAt]
}

enum CSVTableError: Error, CustomStringConvertible {
    case empty
    case missingRequiredColumn(String)
    case fileReadFailed(URL, underlying: Error)
    case fileWriteFailed(URL, underlying: Error)

    var description: String {
        switch self {
        case .empty:
            return "CSV document has no rows (header required)"
        case .missingRequiredColumn(let name):
            return "CSV table missing required column: \(name)"
        case .fileReadFailed(let url, let err):
            return "Failed to read CSV at \(url.lastPathComponent): \(err)"
        case .fileWriteFailed(let url, let err):
            return "Failed to write CSV at \(url.lastPathComponent): \(err)"
        }
    }
}

// MARK: - Serialization (RFC 4180-ish)
//
// We intentionally hand-roll a small RFC 4180 parser/serializer:
// - Numbers + Excel + Sheets all read/write quoted strings with `""` doubling
//   for embedded quotes; line endings are CRLF in their output but we also
//   accept LF (TabularData accepts both as of iOS 16).
// - We avoid TabularData here so the value type works in pure-Swift unit tests
//   that don't link UIKit.
// - Line endings are normalized to `\n` before parsing because Swift's
//   `String.Character` iteration treats `\r\n` as a single grapheme cluster —
//   so a switch on `Character` literal `"\r"` never matches when the input
//   came from a CRLF source. We iterate `unicodeScalars` instead.

extension CSVTable {

    /// Serialize to CSV text. Always CRLF line endings (RFC 4180 §2).
    func serialize() -> String {
        var out = ""
        out.append(Self.escapeRow(header))
        out.append("\r\n")
        for row in rows {
            out.append(Self.escapeRow(row))
            out.append("\r\n")
        }
        return out
    }

    /// Parse CSV text into a `CSVTable`. Throws `CSVTableError.empty` for an
    /// empty document (a real CSV must have at least a header row).
    static func parse(_ text: String) throws -> CSVTable {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parsed = parseRowsLF(normalized)
        guard let head = parsed.first else {
            throw CSVTableError.empty
        }
        let body = Array(parsed.dropFirst())
        // Filter trailing empty rows (final newline after last record).
        let trimmedBody = body.reversed().drop(while: { $0.allSatisfy(\.isEmpty) }).reversed()
        return CSVTable(header: head, rows: Array(trimmedBody))
    }

    /// Returns rows keyed by the reserved `__row_id` column. Rows missing the
    /// column (or whose row_id is empty) are returned as `unkeyed`.
    func partitionedByRowID() -> (keyed: [String: [String]], unkeyed: [[String]]) {
        guard let idx = header.firstIndex(of: CSVReserved.rowID) else {
            return ([:], rows)
        }
        var keyed: [String: [String]] = [:]
        var unkeyed: [[String]] = []
        for row in rows {
            guard idx < row.count else {
                unkeyed.append(row)
                continue
            }
            let id = row[idx]
            if id.isEmpty {
                unkeyed.append(row)
            } else {
                keyed[id] = row
            }
        }
        return (keyed, unkeyed)
    }

    private static func escapeRow(_ cells: [String]) -> String {
        cells.map(Self.escapeCell).joined(separator: ",")
    }

    private static func escapeCell(_ cell: String) -> String {
        let needsQuote = cell.contains(",") || cell.contains("\"") || cell.contains("\n") || cell.contains("\r")
        if needsQuote {
            let escaped = cell.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return cell
    }

    /// Parser variant assuming input has already been normalized so the only
    /// row terminator is `\n` (see `parse(_:)`). We iterate over
    /// `unicodeScalars` rather than `Character` because Swift's grapheme
    /// clustering would otherwise merge consecutive CR/LF into a single
    /// Character that doesn't match any of our `\n` / `,` / `"` cases.
    private static func parseRowsLF(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var cell = ""
        var inQuotes = false

        let scalars = Array(text.unicodeScalars)
        var i = 0
        let quote: Unicode.Scalar = "\""
        let comma: Unicode.Scalar = ","
        let newline: Unicode.Scalar = "\n"

        func endCell() {
            current.append(cell)
            cell = ""
        }
        func endRow() {
            endCell()
            rows.append(current)
            current = []
        }

        while i < scalars.count {
            let s = scalars[i]
            if inQuotes {
                if s == quote {
                    if i + 1 < scalars.count && scalars[i + 1] == quote {
                        cell.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        i += 1
                        continue
                    }
                } else {
                    cell.unicodeScalars.append(s)
                    i += 1
                    continue
                }
            } else {
                if s == quote {
                    inQuotes = true
                    i += 1
                } else if s == comma {
                    endCell()
                    i += 1
                } else if s == newline {
                    endRow()
                    i += 1
                } else {
                    cell.unicodeScalars.append(s)
                    i += 1
                }
            }
        }
        // Flush trailing cell/row if text didn't end with newline.
        if !cell.isEmpty || !current.isEmpty {
            endRow()
        }
        return rows
    }
}
