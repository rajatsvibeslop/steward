//
//  AuditLog.swift
//  Steward
//
//  Single write surface for the `events` audit row that pairs every external
//  agent mutation with a typed InverseAction.
//
//  Why this lives in its own file: per addendum §1.6, every agent action emits
//  an event with `reasoning` (hard reject #11) and a paired InverseAction
//  (hard reject #4). Having ONE writer means every tool in the app uses the
//  same row shape — UndoExecutor can rely on `events.payload_json["turn_action"]`
//  always being present for any kind it cares about.
//
//  Storage model:
//    events.event_id      = TurnAction.id.rawValue  (so action_id == event_id)
//    events.actor         = TurnAction.actor.dbValue
//    events.kind          = TurnAction.toolID.rawValue
//    events.reasoning     = TurnAction.reasoning           (NOT NULL for agents)
//    events.payload_json  = { "turn_action": { ... }, ...extra }
//
//  The events table CHECK constraint already enforces reasoning-NOT-NULL for
//  agent actors. We additionally assert non-empty reasoning in DEBUG so a
//  whitespace-only "reasoning" doesn't slip past.
//

import Foundation
import GRDB

enum AuditLogError: Error, CustomStringConvertible {
    case reasoningEmpty(actor: String, toolID: String)
    case encodingFailed(underlying: Error)
    case writeFailed(underlying: Error)

    var description: String {
        switch self {
        case .reasoningEmpty(let actor, let toolID):
            return "Audit log refused: agent action \(toolID) by \(actor) has empty reasoning."
        case .encodingFailed(let e):
            return "Audit log: payload encode failed: \(e)"
        case .writeFailed(let e):
            return "Audit log: db write failed: \(e)"
        }
    }
}

/// Process-wide audit log writer. Stateless except for an injected
/// DatabaseProvider (for tests).
actor AuditLog {
    static let shared = AuditLog()

    private let provider: DatabaseProvider
    private let encoder: JSONEncoder

    init(provider: DatabaseProvider = .shared) {
        self.provider = provider
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    /// Append an audit event for an agent action and persist the
    /// TurnAction.inverse for future undo. Runs inside a single `db.write { }`.
    ///
    /// `extraPayload` is merged into the JSON object alongside `turn_action`
    /// so tools can record tool-specific metadata (e.g. the new ek_event_id).
    @discardableResult
    func recordAgentAction(
        _ action: TurnAction,
        text: String? = nil,
        domain: String? = nil,
        instrumentID: String? = nil,
        commitmentID: String? = nil,
        source: String? = nil,
        extraPayload: [String: AnyEncodable] = [:]
    ) async throws -> EventID {
        // Hard reject #11 belt-and-braces: the DB CHECK enforces this; we
        // refuse to even build the SQL if reasoning is blank.
        if action.actor.requiresReasoning {
            let trimmed = action.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw AuditLogError.reasoningEmpty(
                    actor: action.actor.dbValue,
                    toolID: action.toolID.rawValue
                )
            }
        }

        let payload = AuditPayload(turnAction: action, extra: extraPayload)
        let payloadJSON: String
        do {
            let data = try encoder.encode(payload)
            guard let s = String(data: data, encoding: .utf8) else {
                throw AuditLogError.encodingFailed(
                    underlying: NSError(
                        domain: "Steward.AuditLog", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "UTF-8 encode failed"]
                    )
                )
            }
            payloadJSON = s
        } catch let e as AuditLogError {
            throw e
        } catch {
            throw AuditLogError.encodingFailed(underlying: error)
        }

        let eventID = EventID(rawValue: action.id.rawValue)
        let createdAtMS = Int64(action.executedAt.timeIntervalSince1970 * 1000)
        let actorDB = action.actor.dbValue
        let kindStr = action.toolID.rawValue
        let reasoning = action.reasoning

        let queue = try await provider.database()
        do {
            try await queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO events
                      (event_id, created_at, actor, kind, domain, instrument_id,
                       commitment_id, text, payload_json, source, reasoning)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        eventID.rawValue,
                        createdAtMS,
                        actorDB,
                        kindStr,
                        domain,
                        instrumentID,
                        commitmentID,
                        text,
                        payloadJSON,
                        source,
                        reasoning
                    ]
                )
            }
        } catch {
            throw AuditLogError.writeFailed(underlying: error)
        }
        return eventID
    }

    /// Append an event that marks an action as undone. Caller passes the
    /// original event_id and the inverse-action-result so the audit log
    /// preserves the chain (`undo`'s payload references the original).
    @discardableResult
    func recordUndo(
        originalEventID: EventID,
        undoneBy: ActorRef,
        reasoning: String,
        appliedAt: Date = Date()
    ) async throws -> EventID {
        if undoneBy.requiresReasoning {
            let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw AuditLogError.reasoningEmpty(
                    actor: undoneBy.dbValue, toolID: "undo"
                )
            }
        }
        let undoID = EventID.generate()
        let createdAtMS = Int64(appliedAt.timeIntervalSince1970 * 1000)

        let payload: [String: String] = [
            "kind": "undo",
            "original_event_id": originalEventID.rawValue
        ]
        let payloadJSON: String
        do {
            let data = try JSONEncoder().encode(payload)
            payloadJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw AuditLogError.encodingFailed(underlying: error)
        }

        let actorDB = undoneBy.dbValue
        let queue = try await provider.database()
        do {
            try await queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO events
                      (event_id, created_at, actor, kind, payload_json, reasoning)
                    VALUES (?, ?, ?, 'undo', ?, ?)
                    """,
                    arguments: [
                        undoID.rawValue,
                        createdAtMS,
                        actorDB,
                        payloadJSON,
                        reasoning
                    ]
                )
            }
        } catch {
            throw AuditLogError.writeFailed(underlying: error)
        }
        return undoID
    }

    /// Load a TurnAction back from the audit log. Returns nil if no event row
    /// exists for that ID; throws if the row exists but its payload is
    /// malformed (so the caller can surface a UI hint rather than silently
    /// skipping undo).
    func loadTurnAction(eventID: EventID) async throws -> TurnAction? {
        let queue = try await provider.database()
        let json: String? = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT payload_json FROM events WHERE event_id = ?",
                arguments: [eventID.rawValue]
            )
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let decoded = try dec.decode(AuditPayload.self, from: data)
            return decoded.turnAction
        } catch {
            throw UndoExecutorError.eventPayloadInvalid(eventID, underlying: error)
        }
    }

    /// `true` if a later event row with kind=`undo` references this event ID.
    func hasBeenUndone(eventID: EventID) async throws -> Bool {
        let queue = try await provider.database()
        return try await queue.read { db in
            // payload_json is small (KBs not MBs); LIKE-scan is fine for v1.
            // v1.1 can add a generated column + index if audit volumes grow.
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM events
                WHERE kind = 'undo'
                  AND payload_json LIKE ?
                """,
                arguments: ["%\"original_event_id\":\"\(eventID.rawValue)\"%"]
            ) ?? 0
            return count > 0
        }
    }
}

// MARK: - Wire format helpers

/// Tiny `Codable` JSON wrapper so tools can attach arbitrary metadata to the
/// event payload without us having to know every shape up front.
struct AnyEncodable: Codable, Sendable {
    private let encoder: @Sendable (Encoder) throws -> Void

    init<T: Encodable & Sendable>(_ value: T) {
        self.encoder = { enc in try value.encode(to: enc) }
    }

    func encode(to encoder: Encoder) throws {
        try self.encoder(encoder)
    }

    init(from decoder: Decoder) throws {
        // We only need encoding for AuditLog; provide a no-op decoder so
        // synthesized Codable conformance still works on enclosing types.
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AnyEncodable(raw)
    }
}

/// On-disk shape of `events.payload_json` for agent actions.
private struct AuditPayload: Codable {
    let turnAction: TurnAction
    let extra: [String: AnyEncodable]?

    enum CodingKeys: String, CodingKey {
        case turnAction = "turn_action"
        case extra
    }

    init(turnAction: TurnAction, extra: [String: AnyEncodable]) {
        self.turnAction = turnAction
        self.extra = extra.isEmpty ? nil : extra
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.turnAction = try c.decode(TurnAction.self, forKey: .turnAction)
        self.extra = try c.decodeIfPresent([String: AnyEncodable].self, forKey: .extra)
    }
}
