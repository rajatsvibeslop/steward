//
//  MemoryDecayJob.swift
//  Steward
//
//  Nightly persistence of effective strength. The reranker uses the lazy
//  value (addendum §1.5); this job persists it back into
//  `strength_at_last_update` and bumps `last_strength_update_at` so indexed
//  sort queries stay accurate. Soft-deletes rows that have fallen below the
//  0.05 threshold (we set strength to 0 — hard-DELETE is reserved for the
//  user-initiated `memory.forget` path).
//

import Foundation
import GRDB

enum MemoryDecayJob {

    struct Outcome: Equatable, Sendable {
        let scanned: Int
        let updated: Int
        let softDeleted: Int
    }

    /// Run the decay pass. Idempotent — running twice in the same second is
    /// a no-op for any row whose `last_strength_update_at == now`.
    @discardableResult
    static func run(now: Date = Date(), in db: Database) throws -> Outcome {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT memory_id, type, strength_at_last_update, last_strength_update_at
                FROM memory_items
            """
        )
        var updated = 0
        var softDeleted = 0
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        for row in rows {
            guard let type = MemoryType(rawValue: row["type"]) else { continue }
            let strength: Double = row["strength_at_last_update"]
            let lastMs: Int64 = row["last_strength_update_at"]
            let last = Date(timeIntervalSince1970: Double(lastMs) / 1000)
            let days = max(0, now.timeIntervalSince(last) / 86_400)
            if days < 1 { continue }   // wait at least a day before persisting decay

            let decayed = strength * pow(type.dailyDecayMultiplier, days)
            let clamped = max(0, min(1, decayed))

            if clamped < 0.05, strength > 0 {
                try db.execute(
                    sql: """
                        UPDATE memory_items
                        SET strength_at_last_update = 0,
                            last_strength_update_at = ?
                        WHERE memory_id = ?
                    """,
                    arguments: [nowMs, row["memory_id"]]
                )
                softDeleted += 1
            } else if abs(clamped - strength) > 0.0005 {
                try db.execute(
                    sql: """
                        UPDATE memory_items
                        SET strength_at_last_update = ?,
                            last_strength_update_at = ?
                        WHERE memory_id = ?
                    """,
                    arguments: [clamped, nowMs, row["memory_id"]]
                )
                updated += 1
            }
        }
        return Outcome(scanned: rows.count, updated: updated, softDeleted: softDeleted)
    }

    /// Periodic persistence pass. Single seam used by both the BGTask refresh
    /// handler and the app-launch one-shot kick (BGTasks are unreliable in
    /// the first install week — see Background/BGTaskCoordinator notes).
    ///
    /// Errors during the write are intentionally caught and reported via the
    /// returned optional rather than rethrown: a transient DB hiccup must
    /// not abort the BGTask refresh cycle that wraps this call.
    /// `MemoryRetriever` applies the lazy decay at query time, so ranking
    /// stays correct between passes; the next tick re-attempts persistence.
    @discardableResult
    static func runPersistencePass(
        on queue: DatabaseQueue,
        now: Date = Date()
    ) async -> Outcome? {
        do {
            return try await queue.write { db in
                try MemoryDecayJob.run(now: now, in: db)
            }
        } catch {
            return nil
        }
    }
}
