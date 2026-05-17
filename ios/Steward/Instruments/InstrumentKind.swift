//
//  InstrumentKind.swift
//  Steward
//
//  Track C: the typed-state-machine protocol every instrument kind conforms to.
//  Owned by Pod C per addendum §1.2. The InstrumentRegistry dispatches by
//  `K.id`; nothing in the app keys behavior off the kind string directly
//  (addendum §4 hard reject #9).
//
//  Math is Swift, not LLM (hard reject #1). Every apply() / migrate() is a
//  pure function of inputs; no Date.now() reads, no random — `now` is passed
//  in so tests stay deterministic.
//

import Foundation

// MARK: - Identifiers

/// String-typed Ids. The DB stores them as TEXT; ULIDs are produced via
/// `ULID.generate()` so cross-table foreign keys collate by insertion order.
typealias InstrumentID = String
typealias EventID      = String
typealias MemoryID     = String
typealias CommitmentID = String
typealias NotificationID = String

// MARK: - Shared shapes

/// One row passed into an instrument updater. `T` is the kind-specific
/// payload (Codable, kind-defined). The wrapping envelope is uniform so
/// the registry can stamp `eventID` / `createdAt` / `actor` before the kind
/// ever sees the payload.
struct InstrumentEvent<Payload: Codable & Sendable>: Codable, Sendable {
    let eventID: EventID
    let instrumentID: InstrumentID
    let kind: String          // event sub-kind (e.g. "spend", "log", "increment")
    let actor: String         // "user" | "system" | "agent:<domain>" | "coordinator"
    let createdAt: Date
    let payload: Payload
    let notes: String?
}

/// A user-initiated correction applied outside the normal event flow.
/// Produced by Pod F's CSV reconciliation when the user hand-edits the
/// instrument's CSV mirror. Each kind decides how to fold it into State.
struct ManualCorrection: Codable, Sendable {
    let correctionID: String
    let rowID: String?        // CSV __row_id if the correction targets a specific row
    let cell: String?         // column name being corrected
    let oldValue: String?     // stringified for audit; kind parses to its own type
    let newValue: String?
    let appliedAt: Date
    let reason: String

    enum CodingKeys: String, CodingKey {
        case correctionID = "correction_id"
        case rowID = "row_id"
        case cell
        case oldValue = "old_value"
        case newValue = "new_value"
        case appliedAt = "applied_at"
        case reason
    }
}

/// Render target for `renderCSV`. Plain rows + a header. Pod F serializes
/// to disk; this struct is the deterministic in-memory shape.
struct CSVTable: Equatable, Sendable {
    let header: [String]      // first three MUST be __row_id, __steward_version, __last_synced_at
    let rows: [[String]]

    /// Convenience initializer — auto-prepends the three mandatory header columns
    /// to whatever kind-specific columns the caller supplies. Caller must
    /// supply matching row values for those columns at the front of each row.
    static func make(kindColumns: [String], rows: [[String]]) -> CSVTable {
        CSVTable(
            header: ["__row_id", "__steward_version", "__last_synced_at"] + kindColumns,
            rows: rows
        )
    }
}

// MARK: - Errors

/// Errors that any kind's `apply()` / `migrate()` / `parseCSVOverride()` may
/// throw. All are typed — no `fatalError` / `precondition` (hard reject #3).
enum InstrumentKindError: Error, CustomStringConvertible, Equatable {
    case invalidDefinition(reason: String)
    case invalidEventPayload(reason: String)
    case invalidStateBlob(reason: String)
    case migrationUnsupported(from: Int, to: Int)
    case unparseableCSV(reason: String)

    var description: String {
        switch self {
        case .invalidDefinition(let r):    return "invalidDefinition: \(r)"
        case .invalidEventPayload(let r):  return "invalidEventPayload: \(r)"
        case .invalidStateBlob(let r):     return "invalidStateBlob: \(r)"
        case .migrationUnsupported(let f, let t):
            return "migrationUnsupported from v\(f) to v\(t)"
        case .unparseableCSV(let r):       return "unparseableCSV: \(r)"
        }
    }
}

// MARK: - InstrumentKind protocol

/// A typed instrument state machine. One conformance per row in spec §6.
///
/// **Why associated types:** the compiler enforces that an event payload
/// for `BoundedBudget` cannot accidentally be fed to `RollingAverage.apply`.
/// The registry erases through JSON at the dispatch boundary; concrete
/// kinds work in fully-typed Swift internally.
protocol InstrumentKind {
    associatedtype Definition: Codable & Sendable
    associatedtype State:      Codable & Sendable & Equatable
    associatedtype EventPayload: Codable & Sendable

    /// Stable string used in the `instruments.kind` column and in tool args.
    /// Must match spec §6's table verbatim.
    static var id: String { get }

    /// Bumped whenever `State`'s on-disk shape changes. `migrate()` is asked
    /// to transform older blobs forward. Adding a brand-new field on State
    /// without bumping this = silently broken decode in prod.
    static var stateVersion: Int { get }

    /// Build the initial State for a new instrument. Called once by
    /// `instrument.create`. Pure function of `definition` + `now`.
    static func initialState(definition: Definition, now: Date) -> State

    /// Fold an event into the current state. Deterministic, side-effect-free.
    /// Throws `InstrumentKindError.invalidEventPayload` on malformed inputs.
    static func apply(
        event: InstrumentEvent<EventPayload>,
        to state: State,
        definition: Definition,
        now: Date
    ) throws -> State

    /// Fold a CSV-edit correction into state without going through the
    /// normal event path. Each kind defines its own semantics (e.g.
    /// BoundedBudget may treat a correction as a manual override of
    /// `period_total`). The correction itself is also written to the
    /// events table by the caller — apply() never writes side effects.
    static func applyManualCorrection(
        _ correction: ManualCorrection,
        to state: State,
        definition: Definition
    ) throws -> State

    /// Forward-migrate a stored state blob whose `state_version` is less than
    /// the registered `stateVersion`. Default impl tries to decode straight
    /// across — kinds override when fields are added/renamed.
    static func migrate(
        state: Data,
        fromVersion: Int,
        definition: Definition
    ) throws -> State

    /// Render the canonical CSV view of this instrument. `recentEvents` is the
    /// last N events (caller chooses N) so kinds can show a sparkline-ish tail.
    static func renderCSV(
        state: State,
        definition: Definition,
        recentEvents: [InstrumentEvent<EventPayload>]
    ) -> CSVTable

    /// Inspect a (possibly user-edited) CSV table and emit a list of
    /// corrections that need to be applied. Pod F's CSVMirrorWatcher calls
    /// this after diffing data.csv against the events table.
    static func parseCSVOverride(
        _ table: CSVTable,
        current: State,
        definition: Definition
    ) throws -> [ManualCorrection]
}

// MARK: - CSV diff helpers (kind-shared)

/// Conveniences used by every kind's `parseCSVOverride`. Centralized so the
/// "for each row, compare cell N against state's nth entry, emit
/// `ManualCorrection` on differ" pattern is one place to audit.
enum CSVDiff {

    /// Header index → 3 meta columns + kind columns. `__row_id, __steward_version,
    /// __last_synced_at` are the first three. Returns nil if the table doesn't
    /// have at least the requested column.
    static func cellAt(row: [String], header: [String], column: String) -> String? {
        guard let idx = header.firstIndex(of: column), idx < row.count else { return nil }
        return row[idx]
    }

    /// Iterate (rowIndex, row) pairs that have a corresponding state entry
    /// (i.e., truncated to min(table.rows.count, stateEntryCount)). Skips
    /// "new rows" the user added — those become `log_entry` events at Pod F.
    static func pairedRows<T>(
        table: CSVTable,
        stateEntries: [T]
    ) -> [(rowIndex: Int, row: [String], stateEntry: T)] {
        let limit = min(table.rows.count, stateEntries.count)
        return (0..<limit).map { i in
            (rowIndex: i, row: table.rows[i], stateEntry: stateEntries[i])
        }
    }

    /// Build a single `ManualCorrection`. `appliedAt` defaults to `Date()` —
    /// callers may override for tests. ULID for the correction id.
    static func correction(
        rowID: String?,
        cell: String,
        oldValue: String?,
        newValue: String?,
        appliedAt: Date = Date(),
        reason: String
    ) -> ManualCorrection {
        ManualCorrection(
            correctionID: ULID.generate(now: appliedAt),
            rowID: rowID,
            cell: cell,
            oldValue: oldValue,
            newValue: newValue,
            appliedAt: appliedAt,
            reason: reason
        )
    }
}

// MARK: - Default migrate

extension InstrumentKind {
    /// Default: decode as if the blob is already on the current version.
    /// Kinds with non-trivial migrations override this. If `fromVersion`
    /// equals the current `stateVersion`, this is a straight decode — that's
    /// the no-op happy path and shouldn't fail.
    static func migrate(
        state: Data,
        fromVersion: Int,
        definition: Definition
    ) throws -> State {
        if fromVersion > Self.stateVersion {
            // Downgrade not supported. The DB can't roll back to an older
            // schema without losing data; we surface this explicitly rather
            // than guessing.
            throw InstrumentKindError.migrationUnsupported(
                from: fromVersion,
                to: Self.stateVersion
            )
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(State.self, from: state)
        } catch {
            throw InstrumentKindError.invalidStateBlob(reason: String(describing: error))
        }
    }
}
