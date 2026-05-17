//
//  RecurringRuleStore.swift
//  Steward
//
//  Persistent store for active recurring notification rules
//  (`notification_recurring_rules`, v2 migration). NotificationScheduler reads
//  this on every `topUpHorizon` so the next 7+ days of notifications can be
//  re-issued without depending on BGTasks (researcher landmine: BGTasks are
//  unreliable in install week).
//
//  Single-writer access via DatabaseProvider; the store itself is an actor so
//  concurrent tool calls don't tear writes.
//

import Foundation
import GRDB

public struct RecurringRuleRecord: Sendable, Codable, Equatable {
    public var ruleID: String
    public var rrule: String
    public var kind: NotificationKind
    public var domain: String?
    public var instrumentID: String?
    public var templateContextJSON: String
    public var actionContextJSON: String?
    public var priority: Int
    public var scopeActor: String       // "coordinator" or "agent:<domain>"
    public var createdAt: Date
    public var cancelledAt: Date?

    public init(
        ruleID: String = UUID().uuidString,
        rrule: String,
        kind: NotificationKind,
        domain: String? = nil,
        instrumentID: String? = nil,
        templateContextJSON: String,
        actionContextJSON: String? = nil,
        priority: Int = 0,
        scopeActor: String = "coordinator",
        createdAt: Date = Date(),
        cancelledAt: Date? = nil
    ) {
        self.ruleID = ruleID
        self.rrule = rrule
        self.kind = kind
        self.domain = domain
        self.instrumentID = instrumentID
        self.templateContextJSON = templateContextJSON
        self.actionContextJSON = actionContextJSON
        self.priority = priority
        self.scopeActor = scopeActor
        self.createdAt = createdAt
        self.cancelledAt = cancelledAt
    }
}

public actor RecurringRuleStore {
    public static let shared = RecurringRuleStore()

    private let provider: DatabaseProvider

    public init(provider: DatabaseProvider = .shared) {
        self.provider = provider
    }

    /// Insert a new active rule. Returns the persisted record.
    @discardableResult
    public func insert(_ record: RecurringRuleRecord) async throws -> RecurringRuleRecord {
        let queue = try await provider.database()
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO notification_recurring_rules
                  (rule_id, rrule, kind, domain, instrument_id,
                   template_context_json, action_context_json,
                   priority, scope_actor, created_at, cancelled_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.ruleID,
                    record.rrule,
                    record.kind.rawValue,
                    record.domain,
                    record.instrumentID,
                    record.templateContextJSON,
                    record.actionContextJSON,
                    record.priority,
                    record.scopeActor,
                    Int64(record.createdAt.timeIntervalSince1970 * 1000),
                    record.cancelledAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                ]
            )
        }
        return record
    }

    public func loadActive() async throws -> [RecurringRuleRecord] {
        let queue = try await provider.database()
        return try await queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT rule_id, rrule, kind, domain, instrument_id,
                       template_context_json, action_context_json,
                       priority, scope_actor, created_at, cancelled_at
                FROM notification_recurring_rules
                WHERE cancelled_at IS NULL
                ORDER BY created_at ASC
                """
            )
            return rows.compactMap(Self.decode(row:))
        }
    }

    public func cancel(ruleID: String, at: Date = Date()) async throws {
        let queue = try await provider.database()
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE notification_recurring_rules SET cancelled_at = ? WHERE rule_id = ?",
                arguments: [Int64(at.timeIntervalSince1970 * 1000), ruleID]
            )
        }
    }

    /// Cancel every active rule of a given kind. Used when the agent cancels
    /// "all morningBrief notifications" via `notification.cancel(kind)`.
    public func cancelAll(kind: NotificationKind, at: Date = Date()) async throws -> Int {
        let queue = try await provider.database()
        return try await queue.write { db in
            try db.execute(
                sql: """
                UPDATE notification_recurring_rules
                SET cancelled_at = ?
                WHERE kind = ? AND cancelled_at IS NULL
                """,
                arguments: [Int64(at.timeIntervalSince1970 * 1000), kind.rawValue]
            )
            return db.changesCount
        }
    }

    // MARK: - Private

    private static func decode(row: Row) -> RecurringRuleRecord? {
        guard
            let ruleID: String = row["rule_id"],
            let rrule: String = row["rrule"],
            let kindRaw: String = row["kind"],
            let kind = NotificationKind(rawValue: kindRaw),
            let templateContextJSON: String = row["template_context_json"],
            let priority: Int = row["priority"],
            let scopeActor: String = row["scope_actor"],
            let createdAtMS: Int64 = row["created_at"]
        else { return nil }
        let cancelledAt: Date? = (row["cancelled_at"] as Int64?).map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }
        return RecurringRuleRecord(
            ruleID: ruleID,
            rrule: rrule,
            kind: kind,
            domain: row["domain"],
            instrumentID: row["instrument_id"],
            templateContextJSON: templateContextJSON,
            actionContextJSON: row["action_context_json"],
            priority: priority,
            scopeActor: scopeActor,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMS) / 1000),
            cancelledAt: cancelledAt
        )
    }
}
