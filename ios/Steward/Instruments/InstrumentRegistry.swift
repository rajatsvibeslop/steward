//
//  InstrumentRegistry.swift
//  Steward
//
//  Track C: registry + dispatch for InstrumentKind conformances (addendum §1.2).
//
//  HARD REJECT #9 ENFORCEMENT: nothing outside this file may `switch` on a
//  kind string. The registry is the one allowed dispatch site. New kinds are
//  added by:
//      1. write a new file in Instruments/Kinds/ conforming to InstrumentKind
//      2. add one line to `InstrumentRegistry.bootstrapAll()`
//
//  No other code change.
//

import Foundation
import GRDB

// MARK: - Public dispatch surface

/// Errors surfaced by registry dispatch. Distinct from `InstrumentKindError`
/// because these are framework-level (lookup failure, JSON envelope decode)
/// rather than kind-specific math problems.
enum InstrumentRegistryError: Error, CustomStringConvertible, Equatable {
    case unknownKind(String)
    case instrumentNotFound(InstrumentID)
    case definitionDecodeFailed(reason: String)
    case stateDecodeFailed(reason: String)
    case eventDecodeFailed(reason: String)
    case stateEncodeFailed(reason: String)

    var description: String {
        switch self {
        case .unknownKind(let k):                return "unknownKind: '\(k)' — call InstrumentRegistry.register first"
        case .instrumentNotFound(let id):        return "instrumentNotFound: \(id)"
        case .definitionDecodeFailed(let r):     return "definitionDecodeFailed: \(r)"
        case .stateDecodeFailed(let r):          return "stateDecodeFailed: \(r)"
        case .eventDecodeFailed(let r):          return "eventDecodeFailed: \(r)"
        case .stateEncodeFailed(let r):          return "stateEncodeFailed: \(r)"
        }
    }
}

/// Persisted shape of an instrument row, lifted into Swift after dispatch.
/// Returned by `dispatchApply` so callers don't need to re-fetch.
struct InstrumentRow: Equatable, Sendable {
    let instrumentID: InstrumentID
    let domain: String
    let kindID: String
    let name: String
    let definitionJSON: String
    let stateJSON: String
    let stateVersion: Int
    let createdAt: Date
    let lastUpdatedAt: Date
    let reviewCadence: String?
    let archivedAt: Date?
    let csvMirrorPath: String?
}

/// Singleton registry. Conformances register at app launch via
/// `InstrumentRegistry.bootstrapAll()`.
enum InstrumentRegistry {

    // MARK: - Internal entry table

    /// Type-erased descriptor for one registered kind. The closures fully
    /// encapsulate the kind's associated types — callers never see them.
    fileprivate struct Entry {
        let id: String
        let stateVersion: Int

        /// Decode `eventJSON` (must include `payload` field), decode `stateJSON`
        /// and `definitionJSON`, run `K.apply`, return the new state encoded.
        let applyEventJSON: (_ eventJSON: String,
                             _ stateJSON: String,
                             _ definitionJSON: String,
                             _ now: Date) throws -> String

        /// Initial state for a brand-new instrument from its definition JSON.
        let initialStateJSON: (_ definitionJSON: String, _ now: Date) throws -> String

        /// Migrate an older state blob forward.
        let migrateJSON: (_ stateJSON: String,
                          _ fromVersion: Int,
                          _ definitionJSON: String) throws -> String

        /// Apply a manual correction (Pod F path).
        let applyCorrectionJSON: (_ correction: ManualCorrection,
                                  _ stateJSON: String,
                                  _ definitionJSON: String) throws -> String
    }

    // The registry is an in-memory map; `@main` calls `bootstrapAll()` once
    // before any UI / agent code touches it. NSLock guards concurrent reads
    // because the registry may be touched from multiple actors (agent loop,
    // CSV watcher, settings load). Writes only happen during boot.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    // MARK: - Registration

    /// Register one kind. Idempotent on identical re-registration.
    static func register<K: InstrumentKind>(_ kind: K.Type) {
        let entry = makeEntry(for: kind)
        lock.lock()
        defer { lock.unlock() }
        entries[K.id] = entry
    }

    /// Returns the registered state version for `kindID`. nil if not registered.
    /// Used by the migrator to decide whether to invoke `migrate()`.
    static func currentStateVersion(forKind kindID: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return entries[kindID]?.stateVersion
    }

    /// True iff a kind with that Id has been registered.
    static func isRegistered(_ kindID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[kindID] != nil
    }

    /// Test seam: clear all registrations. DEBUG-only so production cannot
    /// accidentally wipe the dispatch table.
    #if DEBUG
    static func _resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
    #endif

    /// Register every shipped kind. Call once from `@main` before any view
    /// renders or any agent turn runs. Calling more than once is a no-op.
    /// Each line below is a conscious decision — adding a kind is one new
    /// file + one new line here.
    static func bootstrapAll() {
        register(RunningAccumulator.self)
        register(BoundedBudget.self)
        register(RollingAverage.self)
        register(CountdownCommitment.self)
        register(WeeklyEvidenceLog.self)
        register(Checklist.self)
        register(BoundedWindow.self)
    }

    // MARK: - Dispatch

    /// Apply an event to the instrument identified by `instrumentID`.
    /// All work happens inside the caller's `db.write { }` block so the
    /// event insert + state update + sync_queue enqueue are atomic
    /// (researcher landmine: storage / GRDB).
    ///
    /// `eventJSON` is the full JSON-encoded `InstrumentEvent<...>` envelope
    /// for the kind in question (the tool layer constructs this). The
    /// registry decodes `payload` against the kind's associated type.
    @discardableResult
    static func dispatchApply(
        instrumentID: InstrumentID,
        eventJSON: String,
        in db: Database,
        now: Date
    ) throws -> InstrumentRow {
        let row = try loadRow(instrumentID: instrumentID, db: db)

        guard let entry = lookup(row.kindID) else {
            throw InstrumentRegistryError.unknownKind(row.kindID)
        }

        // Forward-migrate stored state if needed BEFORE applying the event.
        // This is the central enforcement of addendum §1.2 state versioning.
        var workingStateJSON = row.stateJSON
        var workingVersion = row.stateVersion
        if workingVersion < entry.stateVersion {
            workingStateJSON = try entry.migrateJSON(
                workingStateJSON,
                workingVersion,
                row.definitionJSON
            )
            workingVersion = entry.stateVersion
        }

        let newStateJSON = try entry.applyEventJSON(
            eventJSON,
            workingStateJSON,
            row.definitionJSON,
            now
        )

        let updatedAt = Int64(now.timeIntervalSince1970 * 1000)
        try db.execute(
            sql: """
                UPDATE instruments
                SET state_json = ?, state_version = ?, last_updated_at = ?
                WHERE instrument_id = ?
            """,
            arguments: [newStateJSON, workingVersion, updatedAt, instrumentID]
        )

        return InstrumentRow(
            instrumentID: row.instrumentID,
            domain: row.domain,
            kindID: row.kindID,
            name: row.name,
            definitionJSON: row.definitionJSON,
            stateJSON: newStateJSON,
            stateVersion: workingVersion,
            createdAt: row.createdAt,
            lastUpdatedAt: now,
            reviewCadence: row.reviewCadence,
            archivedAt: row.archivedAt,
            csvMirrorPath: row.csvMirrorPath
        )
    }

    /// Build the initial state JSON for a new instrument. Used by the
    /// `instrument.create` tool before INSERTing the row.
    static func initialStateJSON(
        forKind kindID: String,
        definitionJSON: String,
        now: Date
    ) throws -> String {
        guard let entry = lookup(kindID) else {
            throw InstrumentRegistryError.unknownKind(kindID)
        }
        return try entry.initialStateJSON(definitionJSON, now)
    }

    /// Apply a CSV-derived correction. Used by Pod F's reconciliation path.
    /// Returns the updated state JSON; caller persists + writes the
    /// `manual_correction` event.
    static func applyCorrection(
        kindID: String,
        correction: ManualCorrection,
        stateJSON: String,
        definitionJSON: String
    ) throws -> String {
        guard let entry = lookup(kindID) else {
            throw InstrumentRegistryError.unknownKind(kindID)
        }
        return try entry.applyCorrectionJSON(correction, stateJSON, definitionJSON)
    }

    // MARK: - Internals

    private static func lookup(_ kindID: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[kindID]
    }

    private static func loadRow(instrumentID: InstrumentID, db: Database) throws -> InstrumentRow {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT instrument_id, domain, kind, name, definition_json, state_json,
                       state_version, created_at, last_updated_at, review_cadence,
                       archived_at, csv_mirror_path
                FROM instruments
                WHERE instrument_id = ?
            """,
            arguments: [instrumentID]
        ) else {
            throw InstrumentRegistryError.instrumentNotFound(instrumentID)
        }

        let created = Date(timeIntervalSince1970: Double(row["created_at"] as Int64) / 1000)
        let updated = Date(timeIntervalSince1970: Double(row["last_updated_at"] as Int64) / 1000)
        let archived: Date? = (row["archived_at"] as Int64?).map {
            Date(timeIntervalSince1970: Double($0) / 1000)
        }

        return InstrumentRow(
            instrumentID: row["instrument_id"],
            domain: row["domain"],
            kindID: row["kind"],
            name: row["name"],
            definitionJSON: row["definition_json"],
            stateJSON: row["state_json"],
            stateVersion: row["state_version"],
            createdAt: created,
            lastUpdatedAt: updated,
            reviewCadence: row["review_cadence"],
            archivedAt: archived,
            csvMirrorPath: row["csv_mirror_path"]
        )
    }

    // MARK: - Type-erasure machinery

    private static func makeEntry<K: InstrumentKind>(for _: K.Type) -> Entry {
        Entry(
            id: K.id,
            stateVersion: K.stateVersion,
            applyEventJSON: { eventJSON, stateJSON, definitionJSON, now in
                let event = try decodeJSON(InstrumentEvent<K.EventPayload>.self,
                                            from: eventJSON,
                                            wrappingError: InstrumentRegistryError.eventDecodeFailed)
                let state = try decodeJSON(K.State.self,
                                            from: stateJSON,
                                            wrappingError: InstrumentRegistryError.stateDecodeFailed)
                let definition = try decodeJSON(K.Definition.self,
                                                 from: definitionJSON,
                                                 wrappingError: InstrumentRegistryError.definitionDecodeFailed)
                let newState = try K.apply(event: event,
                                            to: state,
                                            definition: definition,
                                            now: now)
                return try encodeJSON(newState,
                                       wrappingError: InstrumentRegistryError.stateEncodeFailed)
            },
            initialStateJSON: { definitionJSON, now in
                let definition = try decodeJSON(K.Definition.self,
                                                 from: definitionJSON,
                                                 wrappingError: InstrumentRegistryError.definitionDecodeFailed)
                let state = K.initialState(definition: definition, now: now)
                return try encodeJSON(state,
                                       wrappingError: InstrumentRegistryError.stateEncodeFailed)
            },
            migrateJSON: { stateJSON, fromVersion, definitionJSON in
                let definition = try decodeJSON(K.Definition.self,
                                                 from: definitionJSON,
                                                 wrappingError: InstrumentRegistryError.definitionDecodeFailed)
                guard let data = stateJSON.data(using: .utf8) else {
                    throw InstrumentRegistryError.stateDecodeFailed(reason: "non-UTF8 state blob")
                }
                let newState = try K.migrate(state: data,
                                              fromVersion: fromVersion,
                                              definition: definition)
                return try encodeJSON(newState,
                                       wrappingError: InstrumentRegistryError.stateEncodeFailed)
            },
            applyCorrectionJSON: { correction, stateJSON, definitionJSON in
                let state = try decodeJSON(K.State.self,
                                            from: stateJSON,
                                            wrappingError: InstrumentRegistryError.stateDecodeFailed)
                let definition = try decodeJSON(K.Definition.self,
                                                 from: definitionJSON,
                                                 wrappingError: InstrumentRegistryError.definitionDecodeFailed)
                let newState = try K.applyManualCorrection(correction,
                                                            to: state,
                                                            definition: definition)
                return try encodeJSON(newState,
                                       wrappingError: InstrumentRegistryError.stateEncodeFailed)
            }
        )
    }
}

// MARK: - JSON helpers (file-private)

private func decodeJSON<T: Decodable>(
    _ type: T.Type,
    from json: String,
    wrappingError: (String) -> InstrumentRegistryError
) throws -> T {
    guard let data = json.data(using: .utf8) else {
        throw wrappingError("non-UTF8 JSON")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode(T.self, from: data)
    } catch {
        throw wrappingError(String(describing: error))
    }
}

private func encodeJSON<T: Encodable>(
    _ value: T,
    wrappingError: (String) -> InstrumentRegistryError
) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    do {
        let data = try encoder.encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw wrappingError("UTF-8 encode failed")
        }
        return s
    } catch let e as InstrumentRegistryError {
        throw e
    } catch {
        throw wrappingError(String(describing: error))
    }
}
