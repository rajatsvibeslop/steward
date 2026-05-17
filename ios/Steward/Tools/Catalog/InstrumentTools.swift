//
//  InstrumentTools.swift
//  Steward
//
//  Spec §8 instrument tools: create / list / read / apply_event /
//  update_definition / archive. All dispatch through InstrumentRegistry
//  (hard reject #9). Math lives in the kinds; tools only orchestrate
//  the DB round-trip.
//

import Foundation
import GRDB

// MARK: - instrument.create

struct InstrumentCreateArgs: Codable, Equatable, Sendable {
    let kind: String
    let name: String
    let domain: String
    /// JSON-encoded definition. Wire format = JSON because the Definition
    /// type is per-kind and the LLM-facing schema can't express a union
    /// cleanly. Decoded by the kind via the registry.
    let definitionJSON: String
    let reviewCadence: String?
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case kind
        case name
        case domain
        case definitionJSON = "definition_json"
        case reviewCadence = "review_cadence"
        case reasoning
        case actor
    }
}

struct InstrumentCreateResult: Codable, Equatable, Sendable {
    let instrumentID: InstrumentID
    let kind: String
    let stateJSON: String
    let stateVersion: Int

    enum CodingKeys: String, CodingKey {
        case instrumentID = "instrument_id"
        case kind
        case stateJSON = "state_json"
        case stateVersion = "state_version"
    }
}

struct InstrumentCreateTool: LLMTool {
    let id: String = ToolID.instrumentCreate.rawValue
    let description: String = "Create a new instrument (typed state machine). Supply kind + definition JSON."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["kind", "name", "domain", "definition_json", "reasoning", "actor"],
      "properties": {
        "kind": {"type": "string"},
        "name": {"type": "string"},
        "domain": {"type": "string"},
        "definition_json": {"type": "string"},
        "review_cadence": {"type": ["string", "null"]},
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
        let args = try ToolJSON.decode(InstrumentCreateArgs.self, from: argsJSON)
        guard InstrumentRegistry.isRegistered(args.kind) else {
            throw LLMToolError(
                code: "unknown_instrument_kind",
                message: "no registered InstrumentKind with id='\(args.kind)'"
            )
        }
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let instrumentID = InstrumentID(rawValue: ULID.generate(now: timestamp))
        let createdMs = Int64(timestamp.timeIntervalSince1970 * 1000)

        let initialState = try InstrumentRegistry.initialStateJSON(
            forKind: args.kind,
            definitionJSON: args.definitionJSON,
            now: timestamp
        )
        let stateVersion = InstrumentRegistry.currentStateVersion(forKind: args.kind) ?? 1

        let db = try await provider.database()
        try await db.write { dbase in
            try dbase.execute(
                sql: """
                    INSERT INTO instruments (
                        instrument_id, domain, kind, name, definition_json, state_json,
                        state_version, created_at, last_updated_at, review_cadence
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    instrumentID,
                    args.domain,
                    args.kind,
                    args.name,
                    args.definitionJSON,
                    initialState,
                    stateVersion,
                    createdMs,
                    createdMs,
                    args.reviewCadence
                ]
            )
            try EventLog.append(
                actor: actor,
                kind: "instrument_create",
                text: args.name,
                domain: args.domain,
                instrumentID: instrumentID,
                payloadJSON: args.definitionJSON,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }

        return try ToolJSON.encode(InstrumentCreateResult(
            instrumentID: instrumentID,
            kind: args.kind,
            stateJSON: initialState,
            stateVersion: stateVersion
        ))
    }
}

// MARK: - instrument.list

struct InstrumentListArgs: Codable, Equatable, Sendable {
    let domain: String?
    let includeArchived: Bool?

    enum CodingKeys: String, CodingKey {
        case domain
        case includeArchived = "include_archived"
    }
}

struct InstrumentListItem: Codable, Equatable, Sendable {
    let instrumentID: InstrumentID
    let domain: String
    let kind: String
    let name: String
    let archived: Bool
    let lastUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case instrumentID = "instrument_id"
        case domain
        case kind
        case name
        case archived
        case lastUpdatedAt = "last_updated_at"
    }
}

struct InstrumentListResult: Codable, Equatable, Sendable {
    let items: [InstrumentListItem]
}

struct InstrumentListTool: LLMTool {
    let id: String = ToolID.instrumentList.rawValue
    let description: String = "Enumerate instruments. Filter by domain; archived hidden by default."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "properties": {
        "domain": {"type": ["string", "null"]},
        "include_archived": {"type": ["boolean", "null"]}
      }
    }
    """

    let provider: DatabaseProvider
    init(provider: DatabaseProvider = .shared) { self.provider = provider }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(InstrumentListArgs.self, from: argsJSON)
        let includeArchived = args.includeArchived ?? false
        let db = try await provider.database()
        let items: [InstrumentListItem] = try await db.read { dbase in
            var sql = """
                SELECT instrument_id, domain, kind, name, archived_at, last_updated_at
                FROM instruments
                WHERE 1=1
            """
            var sqlArgs: [DatabaseValueConvertible?] = []
            if !includeArchived {
                sql += " AND archived_at IS NULL"
            }
            if let domain = args.domain {
                sql += " AND domain = ?"
                sqlArgs.append(domain)
            }
            sql += " ORDER BY last_updated_at DESC"
            let rows = try Row.fetchAll(dbase, sql: sql, arguments: StatementArguments(sqlArgs))
            return rows.map { row in
                InstrumentListItem(
                    instrumentID: row["instrument_id"],
                    domain: row["domain"],
                    kind: row["kind"],
                    name: row["name"],
                    archived: (row["archived_at"] as Int64?) != nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: Double(row["last_updated_at"] as Int64) / 1000)
                )
            }
        }
        return try ToolJSON.encode(InstrumentListResult(items: items))
    }
}

// MARK: - instrument.read

struct InstrumentReadArgs: Codable, Equatable, Sendable {
    let instrumentID: InstrumentID

    enum CodingKeys: String, CodingKey {
        case instrumentID = "instrument_id"
    }
}

struct InstrumentReadResult: Codable, Equatable, Sendable {
    let instrumentID: InstrumentID
    let domain: String
    let kind: String
    let name: String
    let definitionJSON: String
    let stateJSON: String
    let stateVersion: Int
    let lastUpdatedAt: Date
    let archived: Bool

    enum CodingKeys: String, CodingKey {
        case instrumentID = "instrument_id"
        case domain
        case kind
        case name
        case definitionJSON = "definition_json"
        case stateJSON = "state_json"
        case stateVersion = "state_version"
        case lastUpdatedAt = "last_updated_at"
        case archived
    }
}

struct InstrumentReadTool: LLMTool {
    let id: String = ToolID.instrumentRead.rawValue
    let description: String = "Read instrument's current definition + state. The agent MUST cite these numbers verbatim."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["instrument_id"],
      "properties": {
        "instrument_id": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    init(provider: DatabaseProvider = .shared) { self.provider = provider }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(InstrumentReadArgs.self, from: argsJSON)
        let db = try await provider.database()
        let row: InstrumentReadResult = try await db.read { dbase in
            guard let row = try Row.fetchOne(
                dbase,
                sql: """
                    SELECT instrument_id, domain, kind, name, definition_json, state_json,
                           state_version, last_updated_at, archived_at
                    FROM instruments WHERE instrument_id = ?
                """,
                arguments: [args.instrumentID]
            ) else {
                throw LLMToolError(
                    code: "instrument_not_found",
                    message: "no instrument with id='\(args.instrumentID)'"
                )
            }
            return InstrumentReadResult(
                instrumentID: row["instrument_id"],
                domain: row["domain"],
                kind: row["kind"],
                name: row["name"],
                definitionJSON: row["definition_json"],
                stateJSON: row["state_json"],
                stateVersion: row["state_version"],
                lastUpdatedAt: Date(timeIntervalSince1970: Double(row["last_updated_at"] as Int64) / 1000),
                archived: (row["archived_at"] as Int64?) != nil
            )
        }
        return try ToolJSON.encode(row)
    }
}

// MARK: - instrument.apply_event

struct InstrumentApplyEventArgs: Codable, Equatable, Sendable {
    let instrumentID: InstrumentID
    /// The kind-specific event sub-kind (e.g. "spend", "log", "push_back").
    /// For Checklist this maps to a check/uncheck; for BoundedBudget, a spend.
    let eventKind: String
    /// JSON-encoded `EventPayload` for the kind in question.
    let payloadJSON: String
    let notes: String?
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case instrumentID = "instrument_id"
        case eventKind = "event_kind"
        case payloadJSON = "payload_json"
        case notes
        case reasoning
        case actor
    }
}

struct InstrumentApplyEventResult: Codable, Equatable, Sendable {
    let eventID: EventID
    let instrumentID: InstrumentID
    let newStateJSON: String
    let stateVersion: Int

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case instrumentID = "instrument_id"
        case newStateJSON = "new_state_json"
        case stateVersion = "state_version"
    }
}

struct InstrumentApplyEventTool: LLMTool {
    let id: String = ToolID.instrumentApplyEvent.rawValue
    let description: String = "Apply an event to an instrument. State is recomputed in Swift; tool returns the new state JSON."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["instrument_id", "event_kind", "payload_json", "reasoning", "actor"],
      "properties": {
        "instrument_id": {"type": "string"},
        "event_kind": {"type": "string"},
        "payload_json": {"type": "string"},
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
        let args = try ToolJSON.decode(InstrumentApplyEventArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let eventID = EventID(rawValue: ULID.generate(now: timestamp))

        // Build the InstrumentEvent envelope JSON the registry expects.
        // payload_json must already match the kind's EventPayload shape;
        // the agent is responsible for that (we surface decode errors).
        let envelopeJSON = try InstrumentTools.makeEventEnvelopeJSON(
            eventID: eventID,
            instrumentID: args.instrumentID,
            kind: args.eventKind,
            actor: actor.sqlValue,
            createdAt: timestamp,
            payloadJSON: args.payloadJSON,
            notes: args.notes
        )

        let db = try await provider.database()
        let result: InstrumentApplyEventResult = try await db.write { dbase in
            // Atomic: insert event + dispatch state update inside one write.
            try EventLog.append(
                actor: actor,
                kind: args.eventKind,
                text: args.notes,
                instrumentID: args.instrumentID,
                payloadJSON: args.payloadJSON,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                eventID: eventID,
                in: dbase
            )
            let row = try InstrumentRegistry.dispatchApply(
                instrumentID: args.instrumentID,
                eventJSON: envelopeJSON,
                in: dbase,
                now: timestamp
            )
            return InstrumentApplyEventResult(
                eventID: eventID,
                instrumentID: row.instrumentID,
                newStateJSON: row.stateJSON,
                stateVersion: row.stateVersion
            )
        }
        return try ToolJSON.encode(result)
    }
}

// MARK: - instrument.update_definition

struct InstrumentUpdateDefinitionArgs: Codable, Equatable, Sendable {
    let instrumentID: InstrumentID
    /// Full replacement definition JSON. We do NOT do a per-field patch — the
    /// agent decides what the new definition is in full; partial-patch
    /// semantics live in v2.
    let newDefinitionJSON: String
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case instrumentID = "instrument_id"
        case newDefinitionJSON = "new_definition_json"
        case reasoning
        case actor
    }
}

struct InstrumentUpdateDefinitionResult: Codable, Equatable, Sendable {
    let instrumentID: InstrumentID
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case instrumentID = "instrument_id"
        case updatedAt = "updated_at"
    }
}

struct InstrumentUpdateDefinitionTool: LLMTool {
    let id: String = ToolID.instrumentUpdateDefinition.rawValue
    let description: String = "Replace an instrument's definition (targets, units, cadence). State is left alone."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["instrument_id", "new_definition_json", "reasoning", "actor"],
      "properties": {
        "instrument_id": {"type": "string"},
        "new_definition_json": {"type": "string"},
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
        let args = try ToolJSON.decode(InstrumentUpdateDefinitionArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let nowMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        let db = try await provider.database()
        try await db.write { dbase in
            guard try Int.fetchOne(
                dbase,
                sql: "SELECT COUNT(*) FROM instruments WHERE instrument_id = ?",
                arguments: [args.instrumentID]
            ) == 1 else {
                throw LLMToolError(
                    code: "instrument_not_found",
                    message: "no instrument with id='\(args.instrumentID)'"
                )
            }
            try dbase.execute(
                sql: """
                    UPDATE instruments
                    SET definition_json = ?, last_updated_at = ?
                    WHERE instrument_id = ?
                """,
                arguments: [args.newDefinitionJSON, nowMs, args.instrumentID]
            )
            try EventLog.append(
                actor: actor,
                kind: "instrument_update_definition",
                instrumentID: args.instrumentID,
                payloadJSON: args.newDefinitionJSON,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(InstrumentUpdateDefinitionResult(
            instrumentID: args.instrumentID,
            updatedAt: timestamp
        ))
    }
}

// MARK: - instrument.archive

struct InstrumentArchiveArgs: Codable, Equatable, Sendable {
    let instrumentID: InstrumentID
    let reason: String
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case instrumentID = "instrument_id"
        case reason
        case reasoning
        case actor
    }
}

struct InstrumentArchiveResult: Codable, Equatable, Sendable {
    let instrumentID: InstrumentID
    let archivedAt: Date

    enum CodingKeys: String, CodingKey {
        case instrumentID = "instrument_id"
        case archivedAt = "archived_at"
    }
}

struct InstrumentArchiveTool: LLMTool {
    let id: String = ToolID.instrumentArchive.rawValue
    let description: String = "Archive an instrument (sets archived_at). Reversible via undo."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["instrument_id", "reason", "reasoning", "actor"],
      "properties": {
        "instrument_id": {"type": "string"},
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
        let args = try ToolJSON.decode(InstrumentArchiveArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let nowMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        let db = try await provider.database()
        try await db.write { dbase in
            try dbase.execute(
                sql: """
                    UPDATE instruments
                    SET archived_at = ?, last_updated_at = ?
                    WHERE instrument_id = ?
                """,
                arguments: [nowMs, nowMs, args.instrumentID]
            )
            try EventLog.append(
                actor: actor,
                kind: "instrument_archive",
                text: args.reason,
                instrumentID: args.instrumentID,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(InstrumentArchiveResult(
            instrumentID: args.instrumentID,
            archivedAt: timestamp
        ))
    }
}

// MARK: - Shared helpers

enum InstrumentTools {
    /// Construct the `InstrumentEvent` JSON envelope the registry expects.
    /// `payloadJSON` is the kind-specific payload, already typed by the LLM.
    /// We can't statically type it here without losing per-kind dispatch, so
    /// we splice raw JSON. The registry decodes against `K.EventPayload`.
    static func makeEventEnvelopeJSON(
        eventID: EventID,
        instrumentID: InstrumentID,
        kind: String,
        actor: String,
        createdAt: Date,
        payloadJSON: String,
        notes: String?
    ) throws -> String {
        // Validate payloadJSON is parseable JSON before splicing — surfaces
        // bad input as a typed error instead of a SQL/JSON exception later.
        guard let payloadData = payloadJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: payloadData)) != nil else {
            throw LLMToolError(
                code: "invalid_payload_json",
                message: "payload_json must be a valid JSON object"
            )
        }
        let iso = ISO8601DateFormatter()
        let envelope: [String: Any] = [
            "eventID": eventID.rawValue,
            "instrumentID": instrumentID.rawValue,
            "kind": kind,
            "actor": actor,
            "createdAt": iso.string(from: createdAt),
            "payload": (try? JSONSerialization.jsonObject(with: payloadData)) ?? [:],
            "notes": notes as Any
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
