//
//  CSVMirrorWatcher.swift
//  Steward — Track F
//
//  Implements the deterministic reconciliation algorithm from
//  implementation-addendum §1.4. Owns:
//   - `NSFilePresenter` conformance via `CSVPresenter` (separate class because
//     NSFilePresenter is `@objc` and must be a class, not an actor)
//   - The reconcile loop: conflict-union-merge → cell diff → emit events →
//     re-render state.csv
//   - Per-file `__row_id` bookkeeping
//   - Resolution of `old_value` + `original_event_id` for each correction by
//     querying the `events` table for the most recent prior write of the
//     same `(row_id, cell_name)` (addendum §1.4 step 3 payload shape).
//
//  Hard rejects enforced here:
//   - #9 NO string-keyed kind dispatch. `renderState` / `initialDataTable` /
//     `renderData` all go through `InstrumentCSVCoderRegistry.coder(for:)`.
//     The watcher never branches on `snap.kind == "..."`.
//   - #13 state.csv is NEVER re-ingested. `reconcile` reads `data.csv` only.
//     `state.csv` is written by `renderState(_:to:)` and never opened for read.
//   - #3 typed `CSVMirrorWatcherError` only — no fatalError / preconditionFailure.
//   - #11 every emitted agent-source event includes a non-nil `reasoning`
//     string ("user edited <instrument>.csv at <ts>").
//

import Foundation
import GRDB

enum CSVMirrorWatcherError: Error, CustomStringConvertible {
    case instrumentNotFound(instrumentID: String)
    case coderNotRegistered(kindID: String)
    case fileCoordinationFailed(URL, underlying: Error)
    case parseFailed(URL, underlying: Error)
    case conflictResolutionFailed(URL, underlying: Error)
    case dbWriteFailed(underlying: Error)

    var description: String {
        switch self {
        case .instrumentNotFound(let id):
            return "No instrument row for id \(id)"
        case .coderNotRegistered(let kindID):
            return "No InstrumentCSVCoder registered for kind '\(kindID)'"
        case .fileCoordinationFailed(let url, let err):
            return "NSFileCoordinator failed on \(url.lastPathComponent): \(err)"
        case .parseFailed(let url, let err):
            return "CSV parse failed for \(url.lastPathComponent): \(err)"
        case .conflictResolutionFailed(let url, let err):
            return "Conflict resolution failed for \(url.lastPathComponent): \(err)"
        case .dbWriteFailed(let err):
            return "Database write failed during reconciliation: \(err)"
        }
    }
}

/// Resolved-after-conflict view of a file: the bytes we'll actually parse,
/// the canonical (merged) table the bytes encode, plus pre-computed forced
/// corrections for cells where versions disagreed.
struct ResolvedFile: Sendable {
    let url: URL
    let bytes: Data
    let mergedTable: CSVTable?
    /// Cells the conflict-merge had to choose a winner for. These get emitted
    /// as `manual_correction` events with `requires_user_attention=true` per
    /// addendum §1.4 step 1.
    let disagreements: [ManualCorrection]
    var cameFromConflictMerge: Bool { mergedTable != nil }
}

/// Snapshot of an instrument row we need during reconciliation. Includes only
/// the columns the watcher reads.
struct InstrumentSnapshot: Sendable {
    let instrumentID: String
    let domain: String
    let kind: String
    let name: String
    let definitionJSON: String
    let stateJSON: String
}

/// Resolution of a prior write of `(row_id, cell_name)`. Looked up from the
/// `events` table when the watcher needs to fill in `old_value` /
/// `original_event_id` on a new `manual_correction` event.
private struct PriorCellWrite {
    let value: String
    let eventID: String
}

actor CSVMirrorWatcher {
    private let paths: CSVMirrorPaths
    private let provider: DatabaseProvider
    private let registry: InstrumentCSVCoderRegistry
    private let now: @Sendable () -> Date

    /// Active presenters keyed by URL. Strong refs so the OS keeps notifying.
    /// Each entry also carries the instrumentID so `presentedItemDidChange`
    /// knows which row to reconcile.
    private var presenters: [URL: (presenter: CSVPresenter, instrumentID: String)] = [:]

    init(
        paths: CSVMirrorPaths,
        provider: DatabaseProvider = .shared,
        registry: InstrumentCSVCoderRegistry = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.provider = provider
        self.registry = registry
        self.now = now
    }

    // MARK: - Public surface

    /// Begin watching every data.csv currently on disk. For each file we
    /// resolve its `instrumentID` from the path layout (`instruments/<domain>/
    /// <name>/data.csv` → `SELECT instrument_id FROM instruments WHERE
    /// domain=? AND name=?`) and register a presenter that reconciles by id
    /// on every change. Idempotent.
    func startWatching() async throws {
        try writeRootREADMEIfMissing()
        let fm = FileManager.default
        let instrumentsRoot = paths.instrumentsRootURL
        guard let domainsEnum = try? fm.contentsOfDirectory(at: instrumentsRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for domainURL in domainsEnum {
            guard (try? domainURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let domain = domainURL.lastPathComponent
            let names = (try? fm.contentsOfDirectory(at: domainURL, includingPropertiesForKeys: nil)) ?? []
            for nameURL in names {
                let dataURL = nameURL.appendingPathComponent("data.csv", isDirectory: false)
                guard fm.fileExists(atPath: dataURL.path) else { continue }
                let name = nameURL.lastPathComponent
                if let instrumentID = try await lookupInstrumentID(domain: domain, name: name) {
                    installPresenter(at: dataURL, instrumentID: instrumentID)
                }
            }
        }
    }

    /// Stop watching all files. Called on app background or signOut paths.
    func stopWatching() {
        for (_, entry) in presenters {
            NSFileCoordinator.removeFilePresenter(entry.presenter)
        }
        presenters.removeAll()
    }

    /// Ensure data.csv + state.csv + README.txt exist for an instrument,
    /// writing initial content via the registered coder. Idempotent.
    func ensureInstrumentFile(instrumentID: String) async throws -> URL {
        let snap = try await loadInstrument(instrumentID: instrumentID)
        let coder = try await requireCoder(for: snap.kind)
        let dataURL = try paths.instrumentDataURL(domain: snap.domain, name: snap.name)
        let stateURL = try paths.instrumentStateURL(domain: snap.domain, name: snap.name)
        let readmeURL = try paths.instrumentREADMEURL(domain: snap.domain, name: snap.name)

        try FileManager.default.createDirectory(
            at: dataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: dataURL.path) {
            let initial = CSVTable(header: coder.initialDataColumns, rows: [])
            try await writeCSV(initial, to: dataURL)
        }
        try await renderState(snap: snap, coder: coder, to: stateURL)
        if !FileManager.default.fileExists(atPath: readmeURL.path) {
            try await writeText(CSVMirrorBoilerplate.instrumentREADME, to: readmeURL)
        }

        installPresenter(at: dataURL, instrumentID: instrumentID)
        return dataURL
    }

    /// Reconcile the on-disk data.csv into events + state, applying the
    /// addendum §1.4 deterministic algorithm. Returns the count of emitted
    /// events so callers can log.
    @discardableResult
    func reconcile(instrumentID: String) async throws -> Int {
        let snap = try await loadInstrument(instrumentID: instrumentID)
        let coder = try await requireCoder(for: snap.kind)
        let dataURL = try paths.instrumentDataURL(domain: snap.domain, name: snap.name)

        // Step 1: conflict resolution. Union-merge across all NSFileVersions
        // (current + unresolved conflict versions), choosing winners
        // cell-by-cell and emitting `requires_user_attention=true`
        // corrections for every disagreement.
        let resolved = try resolveConflictsIfAny(at: dataURL)

        // Use the merged table when we had a conflict so the parser sees the
        // unioned superset of rows. Otherwise parse the raw bytes.
        let table: CSVTable
        if let merged = resolved.mergedTable {
            table = merged
        } else {
            do {
                let text = String(data: resolved.bytes, encoding: .utf8) ?? ""
                table = try CSVTable.parse(text)
            } catch {
                throw CSVMirrorWatcherError.parseFailed(dataURL, underlying: error)
            }
        }

        // Steps 3+4: ask the coder to compute candidate corrections + new
        // entries. The watcher then resolves `old_value` / `original_event_id`
        // and suppresses no-op corrections before emit.
        let override: CSVOverrideResult
        do {
            override = try coder.parseOverride(table, snap.stateJSON, snap.definitionJSON)
        } catch {
            throw CSVMirrorWatcherError.parseFailed(dataURL, underlying: error)
        }

        // Stitch forced conflict-disagreement corrections in front of the
        // coder's diff output so the user-attention flag is preserved even
        // when the coder also detects the same cell.
        let allCandidates = resolved.disagreements + override.corrections
        let resolvedCorrections = try await resolveOldValues(
            candidates: allCandidates,
            instrumentID: snap.instrumentID
        )

        let emittedCount = try await writeEvents(
            corrections: resolvedCorrections,
            newEntries: override.newEntries,
            snap: snap
        )

        // Step 5: re-render state.csv from new instrument state.
        let postSnap = (try? await loadInstrument(instrumentID: instrumentID)) ?? snap
        let stateURL = try paths.instrumentStateURL(domain: postSnap.domain, name: postSnap.name)
        try await renderState(snap: postSnap, coder: coder, to: stateURL)

        // If the merge changed disk contents, write the unioned bytes back.
        if let merged = resolved.mergedTable {
            try await writeCSV(merged, to: dataURL)
        }

        return emittedCount
    }

    // MARK: - Conflict resolution (addendum §1.4 step 1)
    //
    // Algorithm: gather all NSFileVersions for the data.csv, parse each into
    // a `CSVTable`, and merge by `__row_id`:
    //   - row_id present in only some versions → keep the version with the
    //     newest mtime; no per-cell disagreement
    //   - row_id present in multiple versions with disagreeing cells →
    //     choose winner cell by newest-mtime; record each disagreeing cell
    //     as a forced `manual_correction` with `requires_user_attention=true`
    // The merged table becomes the canonical disk content, preserving every
    // row from every version (the previous "newest-wins-and-overwrite"
    // approach silently dropped runner-up rows).

    nonisolated func resolveConflictsIfAny(at url: URL) throws -> ResolvedFile {
        var read: Data?
        var mergedTable: CSVTable?
        var disagreements: [ManualCorrection] = []
        var coordError: NSError?
        var innerError: NSError?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { resolvedURL in
            do {
                let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: resolvedURL) ?? []
                let current = NSFileVersion.currentVersionOfItem(at: resolvedURL)
                if !conflicts.isEmpty {
                    var versions: [(version: NSFileVersion, table: CSVTable, mtime: Date)] = []
                    if let current {
                        let t = try Self.parseVersion(at: resolvedURL)
                        versions.append((current, t, current.modificationDate ?? .distantPast))
                    }
                    for c in conflicts {
                        let t = try Self.parseVersion(at: c.url)
                        versions.append((c, t, c.modificationDate ?? .distantPast))
                    }
                    let (merged, disagrees) = Self.mergeConflictVersions(versions.map { ($0.table, $0.mtime) })
                    mergedTable = merged
                    disagreements = disagrees
                    // Mark every conflict version resolved so iCloud stops
                    // surfacing it. Winning bytes get written back to disk by
                    // the caller (`reconcile`).
                    for c in conflicts {
                        c.isResolved = true
                    }
                }
                read = try Data(contentsOf: resolvedURL)
            } catch {
                innerError = error as NSError
            }
        }

        if let err = coordError {
            throw CSVMirrorWatcherError.conflictResolutionFailed(url, underlying: err)
        }
        if let err = innerError {
            throw CSVMirrorWatcherError.conflictResolutionFailed(url, underlying: err)
        }
        return ResolvedFile(
            url: url,
            bytes: read ?? Data(),
            mergedTable: mergedTable,
            disagreements: disagreements
        )
    }

    /// Pure function — exposed for unit testing. Merges N CSVTables by
    /// `__row_id` union; per-cell winner is whichever version has the latest
    /// mtime. Returns the merged table and a list of forced corrections for
    /// every cell where versions disagreed.
    static func mergeConflictVersions(
        _ versions: [(table: CSVTable, mtime: Date)]
    ) -> (merged: CSVTable, disagreements: [ManualCorrection]) {
        // Empty input → empty merge. Caller's contract is that at least the
        // current version is always present, but we don't crash on misuse
        // (hard reject #3 forbids preconditionFailure / fatalError).
        guard let newest = versions.max(by: { $0.mtime < $1.mtime }) else {
            return (CSVTable(header: [], rows: []), [])
        }
        // Resolve common header by taking the union of column names in the
        // order they appear in the newest version's header.
        var header = newest.table.header
        var headerSet = Set(header)
        for v in versions {
            for col in v.table.header where !headerSet.contains(col) {
                header.append(col)
                headerSet.insert(col)
            }
        }

        // Index every version's rows by row_id.
        struct Indexed {
            let mtime: Date
            let rowsByID: [String: CSVTable.Row]
            let header: [String]
        }
        let indexed: [Indexed] = versions.map { v in
            let (keyed, _) = v.table.partitionedByRowID()
            return Indexed(mtime: v.mtime, rowsByID: keyed, header: v.table.header)
        }

        let allRowIDs: Set<String> = Set(indexed.flatMap { $0.rowsByID.keys })
        var mergedRows: [CSVTable.Row] = []
        var disagreements: [ManualCorrection] = []

        for rowID in allRowIDs.sorted() {
            var cells = Array(repeating: "", count: header.count)
            // Track each cell name's "winner" and any disagreeing values.
            for (colIdx, colName) in header.enumerated() {
                if colName == CSVTable.Reserved.rowID {
                    cells[colIdx] = rowID
                    continue
                }
                // Collect all (value, mtime) pairs that have a non-empty value
                // for this cell across versions that contain this row.
                var observations: [(value: String, mtime: Date)] = []
                for vIdx in indexed.indices {
                    let info = indexed[vIdx]
                    guard let row = info.rowsByID[rowID] else { continue }
                    guard let val = row.value(forColumn: colName, in: info.header) else { continue }
                    observations.append((val, info.mtime))
                }
                guard let winner = observations.max(by: { $0.mtime < $1.mtime }) else {
                    cells[colIdx] = ""
                    continue
                }
                cells[colIdx] = winner.value
                // If any observation disagrees with the winner, emit a forced
                // correction. Reserved/meta columns don't count as user-visible
                // disagreements.
                if !CSVTable.Reserved.all.contains(colName) {
                    let losers = observations.filter { $0.value != winner.value }
                    if !losers.isEmpty {
                        disagreements.append(ManualCorrection(
                            rowID: rowID,
                            cellName: colName,
                            oldValue: losers.first?.value,
                            newValue: winner.value,
                            originalEventID: nil,
                            requiresUserAttention: true
                        ))
                    }
                }
            }
            mergedRows.append(CSVTable.Row(cells: cells))
        }

        return (CSVTable(header: header, rows: mergedRows), disagreements)
    }

    private static func parseVersion(at url: URL) throws -> CSVTable {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? ""
        return try CSVTable.parse(text)
    }

    // MARK: - Old-value + original_event_id resolution
    //
    // For every candidate correction we look up the most recent prior event
    // for the same `(row_id, cell_name)` and fill in `old_value` /
    // `original_event_id`. If the new value equals the resolved old value,
    // we drop the correction (no-op suppression).

    private func resolveOldValues(
        candidates: [ManualCorrection],
        instrumentID: String
    ) async throws -> [ManualCorrection] {
        guard !candidates.isEmpty else { return [] }
        let db = try await provider.database()
        let priors = try await db.read { dbase -> [String: PriorCellWrite] in
            try Self.fetchPriorCells(dbase: dbase, instrumentID: instrumentID)
        }
        var resolved: [ManualCorrection] = []
        for c in candidates {
            let key = priorKey(rowID: c.rowID, cell: c.cellName)
            let prior = priors[key]
            // No-op suppression: skip if the user "edit" matches what
            // Steward (or the user) last wrote.
            if let prior, prior.value == c.newValue { continue }
            resolved.append(ManualCorrection(
                rowID: c.rowID,
                cellName: c.cellName,
                oldValue: c.oldValue ?? prior?.value,
                newValue: c.newValue,
                originalEventID: prior?.eventID,
                requiresUserAttention: c.requiresUserAttention
            ))
        }
        return resolved
    }

    private nonisolated func priorKey(rowID: String, cell: String) -> String {
        "\(rowID)\u{1F}\(cell)"
    }

    /// Pulls the latest `(value, event_id)` per `(row_id, cell_name)` from
    /// every prior `manual_correction` event for the instrument.
    private static func fetchPriorCells(dbase: Database, instrumentID: String) throws -> [String: PriorCellWrite] {
        let rows = try Row.fetchAll(
            dbase,
            sql: """
                SELECT event_id, payload_json, created_at
                FROM events
                WHERE instrument_id = ? AND kind = 'manual_correction'
                ORDER BY created_at ASC
            """,
            arguments: [instrumentID]
        )
        var out: [String: PriorCellWrite] = [:]
        let decoder = JSONDecoder()
        for row in rows {
            let payload: String = row["payload_json"] ?? "{}"
            let eventID: String = row["event_id"] ?? ""
            guard let data = payload.data(using: .utf8) else { continue }
            guard let p = try? decoder.decode(ManualCorrection.self, from: data) else { continue }
            let key = "\(p.rowID)\u{1F}\(p.cellName)"
            // Later events overwrite earlier — `ORDER BY created_at ASC`
            // gives us replay-style latest-wins via dict assignment.
            out[key] = PriorCellWrite(value: p.newValue, eventID: eventID)
        }
        return out
    }

    // MARK: - DB helpers

    private func loadInstrument(instrumentID: String) async throws -> InstrumentSnapshot {
        let db = try await provider.database()
        let row = try await db.read { dbase -> Row? in
            try Row.fetchOne(
                dbase,
                sql: "SELECT instrument_id, domain, kind, name, definition_json, state_json FROM instruments WHERE instrument_id = ?",
                arguments: [instrumentID]
            )
        }
        guard let row else {
            throw CSVMirrorWatcherError.instrumentNotFound(instrumentID: instrumentID)
        }
        return InstrumentSnapshot(
            instrumentID: row["instrument_id"] ?? instrumentID,
            domain: row["domain"] ?? "",
            kind: row["kind"] ?? "",
            name: row["name"] ?? "",
            definitionJSON: row["definition_json"] ?? "{}",
            stateJSON: row["state_json"] ?? "{}"
        )
    }

    private func lookupInstrumentID(domain: String, name: String) async throws -> String? {
        let db = try await provider.database()
        return try await db.read { dbase -> String? in
            try String.fetchOne(
                dbase,
                sql: "SELECT instrument_id FROM instruments WHERE domain = ? AND name = ?",
                arguments: [domain, name]
            )
        }
    }

    private func requireCoder(for kindID: String) async throws -> InstrumentCSVCoder {
        guard let c = await registry.coder(for: kindID) else {
            throw CSVMirrorWatcherError.coderNotRegistered(kindID: kindID)
        }
        return c
    }

    private func writeEvents(
        corrections: [ManualCorrection],
        newEntries: [ManualLogEntry],
        snap: InstrumentSnapshot
    ) async throws -> Int {
        guard !corrections.isEmpty || !newEntries.isEmpty else { return 0 }
        let nowMS = Int64(now().timeIntervalSince1970 * 1000)
        let db = try await provider.database()
        do {
            return try await db.write { dbase -> Int in
                var count = 0
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                for c in corrections {
                    let payloadData = try encoder.encode(c)
                    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
                    let eventID = ULIDFactory.make(now: Date(timeIntervalSince1970: TimeInterval(nowMS) / 1000.0))
                    try dbase.execute(sql: """
                        INSERT INTO events (
                            event_id, created_at, actor, kind, domain,
                            instrument_id, text, payload_json, source, reasoning
                        ) VALUES (?, ?, 'user', 'manual_correction', ?, ?, ?, ?, 'sheets_edit', ?)
                        """, arguments: [
                            eventID,
                            nowMS,
                            snap.domain,
                            snap.instrumentID,
                            "User edited \(snap.name).csv: \(c.cellName) row \(c.rowID) → \(c.newValue)",
                            payloadJSON,
                            "user edited iCloud CSV mirror for instrument \(snap.instrumentID)"
                        ])
                    count += 1
                }
                for e in newEntries {
                    let payloadData = try encoder.encode(e)
                    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
                    let eventID = ULIDFactory.make(now: Date(timeIntervalSince1970: TimeInterval(nowMS) / 1000.0))
                    try dbase.execute(sql: """
                        INSERT INTO events (
                            event_id, created_at, actor, kind, domain,
                            instrument_id, text, payload_json, source, reasoning
                        ) VALUES (?, ?, 'user', 'log_entry', ?, ?, ?, ?, 'sheets_edit', ?)
                        """, arguments: [
                            eventID,
                            nowMS,
                            snap.domain,
                            snap.instrumentID,
                            "New row added in \(snap.name).csv (row_id \(e.assignedRowID))",
                            payloadJSON,
                            "user added row in iCloud CSV mirror for instrument \(snap.instrumentID)"
                        ])
                    count += 1
                }
                return count
            }
        } catch {
            throw CSVMirrorWatcherError.dbWriteFailed(underlying: error)
        }
    }

    // MARK: - State.csv rendering (write-only path; addendum §1.4 + hard reject #13)

    private func renderState(
        snap: InstrumentSnapshot,
        coder: InstrumentCSVCoder,
        to url: URL
    ) async throws {
        let table = try coder.renderState(snap.stateJSON, snap.definitionJSON)
        try await writeCSV(table, to: url)
    }

    // MARK: - File I/O

    func writeCSV(_ table: CSVTable, to url: URL) async throws {
        let bytes = Data(table.serialize().utf8)
        try await writeBytes(bytes, to: url)
    }

    func writeBytes(_ bytes: Data, to url: URL) async throws {
        var coordError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { resolvedURL in
            do {
                try bytes.write(to: resolvedURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let coordError {
            throw CSVMirrorWatcherError.fileCoordinationFailed(url, underlying: coordError)
        }
        if let writeError {
            throw CSVMirrorWatcherError.fileCoordinationFailed(url, underlying: writeError)
        }
    }

    /// Coordinated text write. Used for README files inside the iCloud
    /// container so iCloud sync sees the changes through the file presenter
    /// pipeline (deslop item #9 — uncoordinated writes inside iCloud are a
    /// convention violation).
    func writeText(_ text: String, to url: URL) async throws {
        try await writeBytes(Data(text.utf8), to: url)
    }

    func writeRootREADMEIfMissing() throws {
        let url = paths.rootREADMEURL
        if FileManager.default.fileExists(atPath: url.path) { return }
        var coordError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { resolvedURL in
            do {
                try Data(CSVMirrorBoilerplate.rootREADME.utf8).write(to: resolvedURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let coordError {
            throw CSVMirrorWatcherError.fileCoordinationFailed(url, underlying: coordError)
        }
        if let writeError {
            throw CSVMirrorWatcherError.fileCoordinationFailed(url, underlying: writeError)
        }
    }

    // MARK: - Presenter registration

    /// Install (or refresh) the presenter for a given data.csv that maps back
    /// to a known instrument. Idempotent. Replaces any prior presenter for
    /// the same URL (covers the case where `startWatching` registered a
    /// presenter before `ensureInstrumentFile` was called).
    private func installPresenter(at dataURL: URL, instrumentID: String) {
        if let existing = presenters[dataURL] {
            if existing.instrumentID == instrumentID { return }
            NSFileCoordinator.removeFilePresenter(existing.presenter)
        }
        let presenter = CSVPresenter(dataURL: dataURL) { [weak self] in
            guard let self else { return }
            Task {
                _ = try? await self.reconcile(instrumentID: instrumentID)
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        presenters[dataURL] = (presenter, instrumentID)
    }

    /// Variant kept for callers that have an instrument id but no URL handy.
    func registerPresenter(forInstrument instrumentID: String) async throws {
        let snap = try await loadInstrument(instrumentID: instrumentID)
        let dataURL = try paths.instrumentDataURL(domain: snap.domain, name: snap.name)
        installPresenter(at: dataURL, instrumentID: instrumentID)
    }
}

/// `NSFilePresenter` is `@objc`-required and must be a class; the actor calls
/// into it via a Sendable closure.
final class CSVPresenter: NSObject, NSFilePresenter {
    let dataURL: URL
    private let onChange: @Sendable () -> Void

    let presentedItemOperationQueue: OperationQueue

    init(dataURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.dataURL = dataURL
        self.onChange = onChange
        let q = OperationQueue()
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = q
        super.init()
    }

    var presentedItemURL: URL? { dataURL }

    func presentedItemDidChange() {
        onChange()
    }

    func presentedItemDidGain(_ version: NSFileVersion) {
        // iCloud surfaced a new version (potential conflict). Fire change so
        // reconcile picks it up via `unresolvedConflictVersionsOfItem(at:)`.
        onChange()
    }
}
