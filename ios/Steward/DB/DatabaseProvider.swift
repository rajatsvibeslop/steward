//
//  DatabaseProvider.swift
//  Steward
//
//  Module entry: single-writer DatabaseQueue provider per implementation-addendum §3
//  ("GRDB DatabaseQueue (single-writer) — not DatabasePool").
//
//  Other pods get the queue via `await DatabaseProvider.shared.database()`.
//  The migrator runs on first access; concurrent first-access callers wait on
//  the same Task so the migration runs exactly once.
//

import Foundation
import GRDB

/// Errors surfaced by database setup. Production code throws these; nothing
/// in this file may `fatalError` / `precondition` / force-unwrap.
enum DatabaseProviderError: Error, CustomStringConvertible {
    case documentsDirectoryUnavailable
    case migrationFailed(underlying: Error)
    case openFailed(underlying: Error)

    var description: String {
        switch self {
        case .documentsDirectoryUnavailable:
            return "Could not resolve the user's Documents directory."
        case .migrationFailed(let underlying):
            return "Schema migration failed: \(underlying)"
        case .openFailed(let underlying):
            return "Database open failed: \(underlying)"
        }
    }
}

/// Process-wide single-writer GRDB queue for `~/Documents/steward.sqlite`.
///
/// Concurrency model:
/// - The actor serializes the "open + migrate" critical section. Once the
///   queue is built, callers receive a reference and use GRDB's own
///   serialization (DatabaseQueue is itself a serial actor of sorts).
/// - All writes from app code MUST be wrapped in a single `write { }` block
///   per logical operation so event inserts + instrument state updates +
///   sync_queue enqueues fire atomically (researcher landmine).
actor DatabaseProvider {
    static let shared = DatabaseProvider()

    private enum State {
        case unopened
        case opening(Task<DatabaseQueue, Error>)
        case open(DatabaseQueue)
    }

    private var state: State = .unopened
    private let location: DatabaseLocation

    init(location: DatabaseLocation = .userDocuments) {
        self.location = location
    }

    /// Returns the shared queue, opening + migrating on first call.
    func database() async throws -> DatabaseQueue {
        switch state {
        case .open(let queue):
            return queue
        case .opening(let task):
            return try await task.value
        case .unopened:
            let location = self.location
            let task = Task<DatabaseQueue, Error> {
                try Self.openAndMigrate(location: location)
            }
            state = .opening(task)
            do {
                let queue = try await task.value
                state = .open(queue)
                return queue
            } catch {
                // Reset so a subsequent caller can retry rather than wedging.
                state = .unopened
                throw error
            }
        }
    }

    #if DEBUG
    /// Resets the provider. Test-only seam: production has one process-wide
    /// instance that lives for the app lifetime. Gated behind `#if DEBUG` so
    /// the symbol literally does not exist in Release builds — a future pod
    /// cannot accidentally nuke the queue from production code.
    func _resetForTesting() {
        state = .unopened
    }
    #endif

    // MARK: - Private

    private static func openAndMigrate(location: DatabaseLocation) throws -> DatabaseQueue {
        let url: URL
        switch location {
        case .userDocuments:
            url = try resolveDocumentsURL().appendingPathComponent("steward.sqlite")
        case .file(let explicit):
            url = explicit
        }

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "steward.db"
        // Foundation Models / agent loop work is mostly read; only the orchestrator
        // writes. Keep busyMode bounded so we surface contention rather than hang.
        configuration.busyMode = .timeout(2.0)

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            throw DatabaseProviderError.openFailed(underlying: error)
        }

        do {
            try Migrations.migrator.migrate(queue)
        } catch {
            throw DatabaseProviderError.migrationFailed(underlying: error)
        }
        return queue
    }

    private static func resolveDocumentsURL() throws -> URL {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let first = urls.first else {
            throw DatabaseProviderError.documentsDirectoryUnavailable
        }
        return first
    }
}

/// Where the database lives. Tests use `.file(temporary URL)` so they don't
/// touch the user's real Documents directory.
enum DatabaseLocation {
    case userDocuments
    case file(URL)
}
