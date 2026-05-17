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
//   - State updates routed through `InstrumentRegistry.applyCorrection`
//
//  Hard rejects enforced here:
//   - #9 NO string-keyed kind dispatch. `renderState` / `renderData` /
//     `parseOverride` all go through `InstrumentCSVCoderRegistry.coder(for:)`.
//   - #13 state.csv is NEVER re-ingested. `reconcile` reads `data.csv` only.
//     `state.csv` is written by `renderState(_:to:)` and never opened for read.
//   - #3 typed `CSVMirrorWatcherError` only — no fatalError / preconditionFailure.
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
    /// as `manual_correction` events with `reason` containing the
    /// `conflict_resolution_user_attention` marker per addendum §1.4 step 1.
    let disagreements: [ManualCorrection]
    var cameFromConflictMerge: Bool { mergedTable != nil }
}

/// Snapshot of an instrument row we need during reconciliation.
struct InstrumentSnapshot: Sendable {
    let instrumentID: String
    let domain: String
    let kind: String
    let name: String
    let definitionJSON: String
    let stateJSON: String
}

/// Marker prefix written into `ManualCorrection.reason` when the correction
/// originated from a conflict-merge disagreement. The next-turn coordinator
/// context surfaces these as "the user should review this cell". Encoded in
/// the reason string because Pod C's `ManualCorrection` doesn't carry a
/// dedicated `requires_user_attention` flag in v1.
let CSVMirrorConflictReasonPrefix = "conflict_resolution:requires_user_attention "

actor CSVMirrorWatcher {
    private let paths: CSVMirrorPaths
    private let provider: DatabaseProvider
    private let registry: InstrumentCSVCoderRegistry
    private let now: @Sendable () -> Date

    /// Active presenters keyed by URL, each tagged with the instrumentID so
    /// `presentedItemDidChange` knows which row to reconcile.
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

    /// Stop watching all files.
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
            // Initial data.csv from `renderCSV` against current state + no
            // events. For a brand-new instrument this yields the header row
            // alone (most kinds' renderCSV returns no rows when state is fresh).
            let initial = try coder.renderData(snap.stateJSON, snap.definitionJSON, [])
            try await writeCSV(initial, to: dataURL)
        }
        try await renderStateFile(snap: snap, coder: coder, to: stateURL)
        if !FileManager.default.fileExists(atPath: readmeURL.path) {
            try await writeText(CSVMirrorBoilerplate.instrumentREADME, to: readmeURL)
        }

        installPresenter(at: dataURL, instrumentID: instrumentID)
        return dataURL
    }

    /// Reconcile the on-disk data.csv into events + state, applying the
    /// addendum §1.4 algorithm. Returns the count of emitted `manual_correction`
    /// events so callers can log.
    @discardableResult
    func reconcile(instrumentID: String) async throws -> Int {
        let snap = try await loadInstrument(instrumentID: instrumentID)
        let coder = try await requireCoder(for: snap.kind)
        let dataURL = try paths.instrumentDataURL(domain: snap.domain, name: snap.name)

        // Step 1: union-merge across all NSFileVersions if there's a conflict.
        let resolved = try resolveConflictsIfAny(at: dataURL)

        // Parse the merged table (or raw bytes when there was no conflict).
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

        // Steps 3+4: ask the coder for corrections from the user-edited table.
        let coderCorrections: [ManualCorrection]
        do {
            coderCorrections = try coder.parseOverride(table, snap.stateJSON, snap.definitionJSON)
        } catch {
            throw CSVMirrorWatcherError.parseFailed(dataURL, underlying: error)
        }

        let allCorrections = resolved.disagreements + coderCorrections

        // Emit each correction as a `manual_correction` event AND fold it
        // into instrument state via Pod C's registry. Single db.write so
        // event insert + state update + sync_queue enqueue are atomic.
        let emittedCount = try await writeCorrections(
            allCorrections,
            snap: snap
        )

        // Step 5: re-render state.csv from new instrument state.
        let postSnap = (try? await loadInstrument(instrumentID: instrumentID)) ?? snap
        let stateURL = try paths.instrumentStateURL(domain: postSnap.domain, name: postSnap.name)
        try await renderStateFile(snap: postSnap, coder: coder, to: stateURL)

        // If the merge changed disk contents, write the unioned bytes back so
        // iCloud sees one canonical version.
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
    //     as a forced `ManualCorrection` with the conflict reason marker
    // The merged table becomes the canonical disk content, preserving every
    // row from every version.

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
                    var versions: [(table: CSVTable, mtime: Date)] = []
                    if let current {
                        let t = try Self.parseVersion(at: resolvedURL)
                        versions.append((t, current.modificationDate ?? .distantPast))
                    }
                    for c in conflicts {
                        let t = try Self.parseVersion(at: c.url)
                        versions.append((t, c.modificationDate ?? .distantPast))
                    }
                    let (merged, disagrees) = Self.mergeConflictVersions(versions)
                    mergedTable = merged
                    disagreements = disagrees
                    // Mark every conflict version resolved so iCloud stops
                    // surfacing it.
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
    /// mtime. Returns the merged table and a list of `ManualCorrection`s for
    /// every disagreeing cell, each with `reason` prefixed by the conflict
    /// marker (`CSVMirrorConflictReasonPrefix`).
    static func mergeConflictVersions(
        _ versions: [(table: CSVTable, mtime: Date)]
    ) -> (merged: CSVTable, disagreements: [ManualCorrection]) {
        guard let newest = versions.max(by: { $0.mtime < $1.mtime }) else {
            return (CSVTable(header: [], rows: []), [])
        }
        // Union the column names; newest version's column order wins, later
        // versions append columns that didn't exist in newest.
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
            let rowsByID: [String: [String]]
            let header: [String]
        }
        let indexed: [Indexed] = versions.map { v in
            let (keyed, _) = v.table.partitionedByRowID()
            return Indexed(mtime: v.mtime, rowsByID: keyed, header: v.table.header)
        }

        let allRowIDs: Set<String> = Set(indexed.flatMap { $0.rowsByID.keys })
        var mergedRows: [[String]] = []
        var disagreements: [ManualCorrection] = []
        let mergeAt = Date()

        for rowID in allRowIDs.sorted() {
            var cells = Array(repeating: "", count: header.count)
            for (colIdx, colName) in header.enumerated() {
                if colName == CSVReserved.rowID {
                    cells[colIdx] = rowID
                    continue
                }
                // Collect (value, mtime) pairs that have a non-nil value for
                // this cell across versions containing this row.
                var observations: [(value: String, mtime: Date)] = []
                for info in indexed {
                    guard let row = info.rowsByID[rowID] else { continue }
                    guard let val = CSVDiff.cellAt(row: row, header: info.header, column: colName) else { continue }
                    observations.append((val, info.mtime))
                }
                guard let winner = observations.max(by: { $0.mtime < $1.mtime }) else {
                    cells[colIdx] = ""
                    continue
                }
                cells[colIdx] = winner.value
                // Disagreement → forced correction (skip reserved/meta cols).
                if !CSVReserved.all.contains(colName) {
                    let losers = observations.filter { $0.value != winner.value }
                    if let loser = losers.first {
                        disagreements.append(ManualCorrection(
                            correctionID: ULID.generate(now: mergeAt),
                            rowID: rowID,
                            cell: colName,
                            oldValue: loser.value,
                            newValue: winner.value,
                            appliedAt: mergeAt,
                            reason: CSVMirrorConflictReasonPrefix + "cell '\(colName)' disagreed across versions"
                        ))
                    }
                }
            }
            mergedRows.append(cells)
        }

        return (CSVTable(header: header, rows: mergedRows), disagreements)
    }

    private static func parseVersion(at url: URL) throws -> CSVTable {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? ""
        return try CSVTable.parse(text)
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

    /// Single `db.write { }` block: for each correction we insert a
    /// `manual_correction` event AND fold the correction into instrument
    /// state via `InstrumentRegistry.applyCorrection`. Either both land or
    /// neither does (researcher landmine: storage / GRDB).
    private func writeCorrections(
        _ corrections: [ManualCorrection],
        snap: InstrumentSnapshot
    ) async throws -> Int {
        guard !corrections.isEmpty else { return 0 }
        let nowMS = Int64(now().timeIntervalSince1970 * 1000)
        let db = try await provider.database()
        do {
            return try await db.write { dbase -> Int in
                var count = 0
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                for c in corrections {
                    // Fold into instrument state first; if Pod C's
                    // applyManualCorrection throws, abort the whole batch.
                    let newStateJSON = try InstrumentRegistry.applyCorrection(
                        kindID: snap.kind,
                        correction: c,
                        stateJSON: snap.stateJSON,
                        definitionJSON: snap.definitionJSON
                    )
                    try dbase.execute(
                        sql: """
                            UPDATE instruments
                            SET state_json = ?, last_updated_at = ?
                            WHERE instrument_id = ?
                        """,
                        arguments: [newStateJSON, nowMS, snap.instrumentID]
                    )

                    let payloadData = try encoder.encode(c)
                    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
                    let eventID = ULID.generate(now: Date(timeIntervalSince1970: TimeInterval(nowMS) / 1000.0))
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
                            "User edited \(snap.name).csv: \(c.cell ?? "(row)") row \(c.rowID ?? "?") → \(c.newValue ?? "")",
                            payloadJSON,
                            "user edited iCloud CSV mirror for instrument \(snap.instrumentID): \(c.reason)"
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

    private func renderStateFile(
        snap: InstrumentSnapshot,
        coder: InstrumentCSVCoder,
        to url: URL
    ) async throws {
        let table = try coder.renderState(snap.stateJSON, snap.definitionJSON)
        try await writeCSV(table, to: url)
    }

    // MARK: - File I/O (all via NSFileCoordinator)

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
    /// the same URL with a different instrumentID.
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

    /// Wrapper for callers that have an instrumentID but no URL handy.
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
        onChange()
    }
}
