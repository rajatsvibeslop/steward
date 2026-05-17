//
//  EventTools.swift
//  Steward
//
//  Spec §8 capture & logging tools: event.capture / event.list /
//  event.recent_summary. The coordinator parses freeform user messages into
//  these calls; tools INSERT into the events table only (hard reject #10).
//

import Foundation
import GRDB

// MARK: - event.capture

struct EventCaptureArgs: Codable, Equatable, Sendable {
    let text: String
    let domain: String?
    let kind: String?
    let payloadJSON: String?
    /// Required when the actor is an agent / coordinator (hard reject #11).
    let reasoning: String
    /// Identifies the caller for the actor column. "coordinator" |
    /// "agent:<domain>" | "user". Wire-format expressed as a string so the
    /// LLM can supply it from a generated arg schema.
    let actor: String

    enum CodingKeys: String, CodingKey {
        case text
        case domain
        case kind
        case payloadJSON = "payload_json"
        case reasoning
        case actor
    }
}

struct EventCaptureResult: Codable, Equatable, Sendable {
    let eventID: EventID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case createdAt = "created_at"
    }
}

struct EventCaptureTool: LLMTool {
    let id: String = ToolID.eventCapture.rawValue
    let description: String = "Log a freeform event. Use when the user reports something happened."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["text", "reasoning", "actor"],
      "properties": {
        "text": {"type": "string"},
        "domain": {"type": ["string", "null"]},
        "kind": {"type": ["string", "null"]},
        "payload_json": {"type": ["string", "null"]},
        "reasoning": {"type": "string"},
        "actor": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let now: @Sendable () -> Date

    init(provider: DatabaseProvider = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(EventCaptureArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let db = try await provider.database()
        let eventID = try await db.write { dbase in
            try EventLog.append(
                actor: actor,
                kind: args.kind ?? "log_entry",
                text: args.text,
                domain: args.domain,
                payloadJSON: args.payloadJSON,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(EventCaptureResult(eventID: eventID, createdAt: timestamp))
    }
}

// MARK: - event.list

struct EventListArgs: Codable, Equatable, Sendable {
    let domain: String?
    let since: Date?
    let limit: Int?
}

struct EventListItem: Codable, Equatable, Sendable {
    let eventID: EventID
    let createdAt: Date
    let actor: String
    let kind: String
    let domain: String?
    let text: String?
    let payloadJSON: String?
    let reasoning: String?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case createdAt = "created_at"
        case actor
        case kind
        case domain
        case text
        case payloadJSON = "payload_json"
        case reasoning
    }
}

struct EventListResult: Codable, Equatable, Sendable {
    let items: [EventListItem]
}

struct EventListTool: LLMTool {
    let id: String = ToolID.eventList.rawValue
    let description: String = "List recent events. Use to inspect history without parsing free text."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "properties": {
        "domain": {"type": ["string", "null"]},
        "since": {"type": ["string", "null"], "format": "date-time"},
        "limit": {"type": ["integer", "null"], "minimum": 1, "maximum": 200}
      }
    }
    """

    let provider: DatabaseProvider
    init(provider: DatabaseProvider = .shared) { self.provider = provider }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(EventListArgs.self, from: argsJSON)
        let limit = min(max(args.limit ?? 20, 1), 200)
        let db = try await provider.database()
        let items: [EventListItem] = try await db.read { dbase in
            var sql = """
                SELECT event_id, created_at, actor, kind, domain, text, payload_json, reasoning
                FROM events
                WHERE 1=1
            """
            var sqlArgs: [DatabaseValueConvertible?] = []
            if let domain = args.domain {
                sql += " AND domain = ?"
                sqlArgs.append(domain)
            }
            if let since = args.since {
                sql += " AND created_at >= ?"
                sqlArgs.append(Int64(since.timeIntervalSince1970 * 1000))
            }
            sql += " ORDER BY created_at DESC LIMIT \(limit)"
            let rows = try Row.fetchAll(dbase, sql: sql, arguments: StatementArguments(sqlArgs))
            return rows.map { row in
                EventListItem(
                    eventID: row["event_id"],
                    createdAt: Date(timeIntervalSince1970: Double(row["created_at"] as Int64) / 1000),
                    actor: row["actor"],
                    kind: row["kind"],
                    domain: row["domain"],
                    text: row["text"],
                    payloadJSON: row["payload_json"],
                    reasoning: row["reasoning"]
                )
            }
        }
        return try ToolJSON.encode(EventListResult(items: items))
    }
}

// MARK: - event.recent_summary

struct EventRecentSummaryArgs: Codable, Equatable, Sendable {
    let domain: String?
    let hours: Int?
}

struct EventRecentSummaryResult: Codable, Equatable, Sendable {
    let windowHours: Int
    let countByKind: [String: Int]
    let domains: [String]
    let firstAt: Date?
    let lastAt: Date?

    enum CodingKeys: String, CodingKey {
        case windowHours = "window_hours"
        case countByKind = "count_by_kind"
        case domains
        case firstAt = "first_at"
        case lastAt = "last_at"
    }
}

/// **Not** a natural-language summary — that would be hard reject #6 territory
/// (LLM composing notification body / user-visible copy from raw data without
/// templates). Instead, we return *structured* counts; the coordinator
/// composes any prose it wants in its own reply, where structured numbers
/// from the tool result back its phrasing.
struct EventRecentSummaryTool: LLMTool {
    let id: String = ToolID.eventRecentSummary.rawValue
    let description: String = "Structured counts over recent events (last N hours)."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "properties": {
        "domain": {"type": ["string", "null"]},
        "hours": {"type": ["integer", "null"], "minimum": 1, "maximum": 168}
      }
    }
    """

    let provider: DatabaseProvider
    let now: @Sendable () -> Date

    init(provider: DatabaseProvider = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(EventRecentSummaryArgs.self, from: argsJSON)
        let windowHours = min(max(args.hours ?? 24, 1), 168)
        let cutoff = now().addingTimeInterval(-Double(windowHours) * 3600)
        let db = try await provider.database()
        let result: EventRecentSummaryResult = try await db.read { dbase in
            var sql = """
                SELECT kind, domain, created_at
                FROM events
                WHERE created_at >= ?
            """
            var sqlArgs: [DatabaseValueConvertible?] = [Int64(cutoff.timeIntervalSince1970 * 1000)]
            if let domain = args.domain {
                sql += " AND domain = ?"
                sqlArgs.append(domain)
            }
            let rows = try Row.fetchAll(dbase, sql: sql, arguments: StatementArguments(sqlArgs))
            var counts: [String: Int] = [:]
            var domainSet: Set<String> = []
            var firstAt: Date?
            var lastAt: Date?
            for row in rows {
                let kind: String = row["kind"]
                counts[kind, default: 0] += 1
                if let d: String = row["domain"] { domainSet.insert(d) }
                let at = Date(timeIntervalSince1970: Double(row["created_at"] as Int64) / 1000)
                if let f = firstAt {
                    if at < f { firstAt = at }
                } else {
                    firstAt = at
                }
                if let l = lastAt {
                    if at > l { lastAt = at }
                } else {
                    lastAt = at
                }
            }
            return EventRecentSummaryResult(
                windowHours: windowHours,
                countByKind: counts,
                domains: Array(domainSet).sorted(),
                firstAt: firstAt,
                lastAt: lastAt
            )
        }
        return try ToolJSON.encode(result)
    }
}

// MARK: - Shared helpers

enum EventTools {
    /// Parse the `actor` wire string into an `EventActor`. String input is
    /// necessarily open-set (the `agent:<domain>` prefix admits any domain
    /// name the user has spawned), so this is an if/else chain rather than
    /// a switch — preserves arch's "no default in any switch" rule by simply
    /// not using a switch.
    static func parseActor(_ wire: String) throws -> EventActor {
        if wire == "user"        { return .user }
        if wire == "system"      { return .system }
        if wire == "coordinator" { return .coordinator }
        if wire.hasPrefix("agent:") {
            let dom = String(wire.dropFirst("agent:".count))
            return .agent(domain: dom)
        }
        throw LLMToolError(
            code: "invalid_actor",
            message: "actor must be one of 'user' | 'system' | 'coordinator' | 'agent:<domain>'; got '\(wire)'"
        )
    }
}
