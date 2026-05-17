//
//  CommitmentTools.swift
//  Steward
//
//  Spec §8 commitment tools: create / list / complete / abandon / snooze.
//  Commitments are promised actions; they mirror to EventKit Reminders via
//  Pod D's gateway (this tool family only writes to the local commitments
//  table — Pod D's tools handle the EventKit side and stash ek_reminder_id
//  via a follow-up update).
//

import Foundation
import GRDB

enum CommitmentStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case active, done, abandoned, snoozed
}

enum CommitmentImportance: String, Codable, Sendable, CaseIterable, Equatable {
    case low, medium, high
}

// MARK: - commitment.create

struct CommitmentCreateArgs: Codable, Equatable, Sendable {
    let title: String
    let domain: String?
    let dueAt: Date?
    let importance: CommitmentImportance
    let linkedInstrumentID: InstrumentID?
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case title
        case domain
        case dueAt = "due_at"
        case importance
        case linkedInstrumentID = "linked_instrument_id"
        case reasoning
        case actor
    }
}

struct CommitmentCreateResult: Codable, Equatable, Sendable {
    let commitmentID: CommitmentID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case commitmentID = "commitment_id"
        case createdAt = "created_at"
    }
}

struct CommitmentCreateTool: LLMTool {
    let id: String = ToolID.commitmentCreate.rawValue
    let description: String = "Create a commitment (a promised action). EventKit mirror is Pod D's job."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["title", "importance", "reasoning", "actor"],
      "properties": {
        "title": {"type": "string"},
        "domain": {"type": ["string", "null"]},
        "due_at": {"type": ["string", "null"], "format": "date-time"},
        "importance": {"type": "string", "enum": ["low","medium","high"]},
        "linked_instrument_id": {"type": ["string", "null"]},
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
        let args = try ToolJSON.decode(CommitmentCreateArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let id = CommitmentID(rawValue: ULID.generate(now: timestamp))
        let nowMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        let dueMs: Int64? = args.dueAt.map { Int64($0.timeIntervalSince1970 * 1000) }

        let db = try await provider.database()
        try await db.write { dbase in
            try dbase.execute(
                sql: """
                    INSERT INTO commitments (
                        commitment_id, title, status, due_at, decision_by, domain,
                        importance, linked_instrument_id, created_at
                    ) VALUES (?, ?, 'active', ?, NULL, ?, ?, ?, ?)
                """,
                arguments: [
                    id,
                    args.title,
                    dueMs,
                    args.domain,
                    args.importance.rawValue,
                    args.linkedInstrumentID,
                    nowMs
                ]
            )
            try EventLog.append(
                actor: actor,
                kind: "commitment_create",
                text: args.title,
                domain: args.domain,
                commitmentID: id,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(CommitmentCreateResult(commitmentID: id, createdAt: timestamp))
    }
}

// MARK: - commitment.list

struct CommitmentListArgs: Codable, Equatable, Sendable {
    let status: CommitmentStatus?
    let domain: String?
}

struct CommitmentListItem: Codable, Equatable, Sendable {
    let commitmentID: CommitmentID
    let title: String
    let status: CommitmentStatus
    let domain: String?
    let dueAt: Date?
    let importance: CommitmentImportance
    let linkedInstrumentID: InstrumentID?
    let createdAt: Date
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case commitmentID = "commitment_id"
        case title
        case status
        case domain
        case dueAt = "due_at"
        case importance
        case linkedInstrumentID = "linked_instrument_id"
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}

struct CommitmentListResult: Codable, Equatable, Sendable {
    let items: [CommitmentListItem]
}

struct CommitmentListTool: LLMTool {
    let id: String = ToolID.commitmentList.rawValue
    let description: String = "List commitments. Filter by status / domain."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "properties": {
        "status": {"type": ["string", "null"], "enum": ["active","done","abandoned","snoozed",null]},
        "domain": {"type": ["string", "null"]}
      }
    }
    """

    let provider: DatabaseProvider
    init(provider: DatabaseProvider = .shared) { self.provider = provider }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(CommitmentListArgs.self, from: argsJSON)
        let db = try await provider.database()
        let items: [CommitmentListItem] = try await db.read { dbase in
            var sql = """
                SELECT commitment_id, title, status, due_at, domain, importance,
                       linked_instrument_id, created_at, completed_at
                FROM commitments
                WHERE 1=1
            """
            var sqlArgs: [DatabaseValueConvertible?] = []
            if let s = args.status {
                sql += " AND status = ?"
                sqlArgs.append(s.rawValue)
            }
            if let d = args.domain {
                sql += " AND domain = ?"
                sqlArgs.append(d)
            }
            sql += " ORDER BY due_at IS NULL, due_at ASC, created_at DESC"
            let rows = try Row.fetchAll(dbase, sql: sql, arguments: StatementArguments(sqlArgs))
            return try rows.map { row in
                guard let status = CommitmentStatus(rawValue: row["status"]) else {
                    throw LLMToolError(
                        code: "corrupt_commitment_status",
                        message: "commitment \(row["commitment_id"] as String): status='\(row["status"] as String)' invalid"
                    )
                }
                guard let imp = CommitmentImportance(rawValue: row["importance"]) else {
                    throw LLMToolError(
                        code: "corrupt_commitment_importance",
                        message: "commitment \(row["commitment_id"] as String): importance='\(row["importance"] as String)' invalid"
                    )
                }
                return CommitmentListItem(
                    commitmentID: row["commitment_id"],
                    title: row["title"],
                    status: status,
                    domain: row["domain"],
                    dueAt: (row["due_at"] as Int64?).map { Date(timeIntervalSince1970: Double($0) / 1000) },
                    importance: imp,
                    linkedInstrumentID: row["linked_instrument_id"],
                    createdAt: Date(timeIntervalSince1970: Double(row["created_at"] as Int64) / 1000),
                    completedAt: (row["completed_at"] as Int64?).map { Date(timeIntervalSince1970: Double($0) / 1000) }
                )
            }
        }
        return try ToolJSON.encode(CommitmentListResult(items: items))
    }
}

// MARK: - Shared transition helper

enum CommitmentTools {
    static func transition(
        commitmentID: CommitmentID,
        to status: CommitmentStatus,
        completedAt: Date?,
        in db: Database
    ) throws {
        let completedMs: Int64? = completedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        if let completedMs {
            try db.execute(
                sql: "UPDATE commitments SET status = ?, completed_at = ? WHERE commitment_id = ?",
                arguments: [status.rawValue, completedMs, commitmentID]
            )
        } else {
            try db.execute(
                sql: "UPDATE commitments SET status = ? WHERE commitment_id = ?",
                arguments: [status.rawValue, commitmentID]
            )
        }
    }
}

// MARK: - commitment.complete

struct CommitmentCompleteArgs: Codable, Equatable, Sendable {
    let commitmentID: CommitmentID
    let notes: String?
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case commitmentID = "commitment_id"
        case notes
        case reasoning
        case actor
    }
}

struct CommitmentTransitionResult: Codable, Equatable, Sendable {
    let commitmentID: CommitmentID
    let status: CommitmentStatus
    let transitionedAt: Date

    enum CodingKeys: String, CodingKey {
        case commitmentID = "commitment_id"
        case status
        case transitionedAt = "transitioned_at"
    }
}

struct CommitmentCompleteTool: LLMTool {
    let id: String = ToolID.commitmentComplete.rawValue
    let description: String = "Mark a commitment as done."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["commitment_id", "reasoning", "actor"],
      "properties": {
        "commitment_id": {"type": "string"},
        "notes": {"type": ["string", "null"]},
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
        let args = try ToolJSON.decode(CommitmentCompleteArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let db = try await provider.database()
        try await db.write { dbase in
            try CommitmentTools.transition(
                commitmentID: args.commitmentID,
                to: .done,
                completedAt: timestamp,
                in: dbase
            )
            try EventLog.append(
                actor: actor,
                kind: "commitment_complete",
                text: args.notes,
                commitmentID: args.commitmentID,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(CommitmentTransitionResult(
            commitmentID: args.commitmentID,
            status: .done,
            transitionedAt: timestamp
        ))
    }
}

// MARK: - commitment.abandon

struct CommitmentAbandonArgs: Codable, Equatable, Sendable {
    let commitmentID: CommitmentID
    let reason: String
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case commitmentID = "commitment_id"
        case reason
        case reasoning
        case actor
    }
}

struct CommitmentAbandonTool: LLMTool {
    let id: String = ToolID.commitmentAbandon.rawValue
    let description: String = "Abandon a commitment (status='abandoned' with logged reason). Not shameful — treated as ordinary."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["commitment_id", "reason", "reasoning", "actor"],
      "properties": {
        "commitment_id": {"type": "string"},
        "reason": {"type": "string"},
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
        let args = try ToolJSON.decode(CommitmentAbandonArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let db = try await provider.database()
        try await db.write { dbase in
            try CommitmentTools.transition(
                commitmentID: args.commitmentID,
                to: .abandoned,
                completedAt: nil,
                in: dbase
            )
            try EventLog.append(
                actor: actor,
                kind: "commitment_abandon",
                text: args.reason,
                commitmentID: args.commitmentID,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(CommitmentTransitionResult(
            commitmentID: args.commitmentID,
            status: .abandoned,
            transitionedAt: timestamp
        ))
    }
}

// MARK: - commitment.snooze

struct CommitmentSnoozeArgs: Codable, Equatable, Sendable {
    let commitmentID: CommitmentID
    let until: Date
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case commitmentID = "commitment_id"
        case until
        case reasoning
        case actor
    }
}

struct CommitmentSnoozeTool: LLMTool {
    let id: String = ToolID.commitmentSnooze.rawValue
    let description: String = "Snooze a commitment to a future date."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["commitment_id", "until", "reasoning", "actor"],
      "properties": {
        "commitment_id": {"type": "string"},
        "until": {"type": "string", "format": "date-time"},
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
        let args = try ToolJSON.decode(CommitmentSnoozeArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let untilMs = Int64(args.until.timeIntervalSince1970 * 1000)
        let db = try await provider.database()
        try await db.write { dbase in
            try dbase.execute(
                sql: """
                    UPDATE commitments
                    SET status = ?, due_at = ?
                    WHERE commitment_id = ?
                """,
                arguments: [CommitmentStatus.snoozed.rawValue, untilMs, args.commitmentID]
            )
            try EventLog.append(
                actor: actor,
                kind: "commitment_snooze",
                payload: ["until": ISO8601DateFormatter().string(from: args.until)],
                commitmentID: args.commitmentID,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(CommitmentTransitionResult(
            commitmentID: args.commitmentID,
            status: .snoozed,
            transitionedAt: timestamp
        ))
    }
}
