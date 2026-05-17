//
//  CSVMirrorTools.swift
//  Steward — Track F
//
//  Implements the three `csv_mirror.*` tools listed in spec §8:
//   - csv_mirror.ensure_instrument_file(instrument_id)
//   - csv_mirror.sync_now()
//   - csv_mirror.read_overrides(instrument_id)
//
//  Each call enqueues a row into `sync_queue` (target='csv_mirror') so the
//  network observer / BG task / next foreground tick can drain pending work.
//  File I/O itself is local — iCloud Drive sync happens transparently in the
//  OS once a network path exists, per spec §13.
//

import Foundation
import GRDB

enum CSVMirrorToolError: Error, CustomStringConvertible {
    case settingsLoadFailed(underlying: Error)
    case watcherNotInitialized
    case mirrorDisabled
    case unknownOperation(String)

    var description: String {
        switch self {
        case .settingsLoadFailed(let err):
            return "Failed to load Settings: \(err)"
        case .watcherNotInitialized:
            return "CSVMirrorTools used before bootstrap — call configure(watcher:) at app launch"
        case .mirrorDisabled:
            return "CSV mirror disabled via Settings.csvMirrorEnabled — tool call ignored"
        case .unknownOperation(let op):
            return "Unknown csv_mirror sync_queue operation '\(op)'"
        }
    }
}

/// Process-wide façade. App bootstrap calls `configure(watcher:)` with the
/// shared `CSVMirrorWatcher` instance; tools then look it up.
actor CSVMirrorTools {
    static let shared = CSVMirrorTools()

    private var watcher: CSVMirrorWatcher?
    private let provider: DatabaseProvider
    private let settings: SettingsStore
    private let now: @Sendable () -> Date

    init(
        provider: DatabaseProvider = .shared,
        settings: SettingsStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.settings = settings
        self.now = now
    }

    func configure(watcher: CSVMirrorWatcher) {
        self.watcher = watcher
    }

    // MARK: - csv_mirror.ensure_instrument_file

    @discardableResult
    func ensureInstrumentFile(instrumentID: String) async throws -> URL {
        try await guardEnabled()
        guard let watcher else { throw CSVMirrorToolError.watcherNotInitialized }
        let url = try await watcher.ensureInstrumentFile(instrumentID: instrumentID)
        try await enqueue(
            operation: "write_instrument_csv",
            payloadJSON: #"{"instrument_id":"\#(instrumentID)"}"#
        )
        return url
    }

    // MARK: - csv_mirror.sync_now

    /// Drain pending `sync_queue` rows with target='csv_mirror'. The current
    /// implementation processes "write_instrument_csv" + "reconcile_user_edits"
    /// + "write_event_log_csv" operations. Pure local I/O — iCloud sync runs
    /// asynchronously in the OS once the file changes.
    @discardableResult
    func syncNow() async throws -> Int {
        try await guardEnabled()
        guard let watcher else { throw CSVMirrorToolError.watcherNotInitialized }
        let db = try await provider.database()
        let pending = try await db.read { dbase in
            try Row.fetchAll(
                dbase,
                sql: """
                    SELECT queue_id, operation, payload_json
                    FROM sync_queue
                    WHERE target = 'csv_mirror' AND completed_at IS NULL
                    ORDER BY enqueued_at ASC
                    LIMIT 50
                """
            )
        }
        var processed = 0
        for row in pending {
            let queueID: String = row["queue_id"] ?? ""
            let operation: String = row["operation"] ?? ""
            let payload: String = row["payload_json"] ?? "{}"
            do {
                // Note: `write_event_log_csv` is NOT handled here — the monthly
                // partitioned event log is v1.1 work, so we deliberately do
                // not accept that operation. If a queue row with an unknown
                // operation lands, mark it completed-with-error so the
                // workflow doesn't spin on the same row every drain.
                switch operation {
                case "write_instrument_csv":
                    if let instrumentID = decodeInstrumentID(from: payload) {
                        _ = try await watcher.ensureInstrumentFile(instrumentID: instrumentID)
                    }
                case "reconcile_user_edits":
                    if let instrumentID = decodeInstrumentID(from: payload) {
                        _ = try await watcher.reconcile(instrumentID: instrumentID)
                    }
                default:
                    throw CSVMirrorToolError.unknownOperation(operation)
                }
                try await markCompleted(queueID: queueID, error: nil)
                processed += 1
            } catch {
                try await markCompleted(queueID: queueID, error: String(describing: error))
            }
        }
        return processed
    }

    // MARK: - csv_mirror.read_overrides

    @discardableResult
    func readOverrides(instrumentID: String) async throws -> Int {
        try await guardEnabled()
        guard let watcher else { throw CSVMirrorToolError.watcherNotInitialized }
        let emitted = try await watcher.reconcile(instrumentID: instrumentID)
        try await enqueue(
            operation: "reconcile_user_edits",
            payloadJSON: #"{"instrument_id":"\#(instrumentID)","emitted_events":\#(emitted)}"#
        )
        return emitted
    }

    // MARK: - Helpers

    private func guardEnabled() async throws {
        let s: Settings
        do {
            s = try await settings.load()
        } catch {
            throw CSVMirrorToolError.settingsLoadFailed(underlying: error)
        }
        if !s.csvMirrorEnabled {
            throw CSVMirrorToolError.mirrorDisabled
        }
    }

    private func enqueue(operation: String, payloadJSON: String) async throws {
        let db = try await provider.database()
        let nowMS = Int64(now().timeIntervalSince1970 * 1000)
        let queueID = ULID.generate(now: now())
        try await db.write { dbase in
            try dbase.execute(sql: """
                INSERT INTO sync_queue (queue_id, target, operation, payload_json, enqueued_at, attempt_count)
                VALUES (?, 'csv_mirror', ?, ?, ?, 0)
                """, arguments: [queueID, operation, payloadJSON, nowMS])
        }
    }

    private func markCompleted(queueID: String, error: String?) async throws {
        let db = try await provider.database()
        let nowMS = Int64(now().timeIntervalSince1970 * 1000)
        try await db.write { dbase in
            try dbase.execute(sql: """
                UPDATE sync_queue
                SET completed_at = ?, attempted_at = ?, attempt_count = attempt_count + 1, last_error = ?
                WHERE queue_id = ?
                """, arguments: [nowMS, nowMS, error, queueID])
        }
    }

    private nonisolated func decodeInstrumentID(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        struct P: Decodable { let instrument_id: String }
        return (try? JSONDecoder().decode(P.self, from: data))?.instrument_id
    }
}
