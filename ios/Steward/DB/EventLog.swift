//
//  EventLog.swift
//  Steward
//
//  Centralized writer for the append-only `events` table. Every tool that
//  mutates state goes through `EventLog.append` so:
//
//  - Hard reject #10: nobody else INSERTs into events; nobody mutates it.
//  - Hard reject #11: agent / coordinator actors MUST provide `reasoning`;
//    the SQL CHECK constraint backs this up but we surface a typed error
//    earlier so the message is actionable.
//
//  Callers run inside their own `db.write { }` block so the event insert and
//  the state change (instrument update / memory insert / etc.) commit
//  atomically (researcher landmine: GRDB).
//

import Foundation
import GRDB

enum EventActor: Equatable, Sendable {
    case user
    case system
    case coordinator
    case agent(domain: String)

    var sqlValue: String {
        switch self {
        case .user:                  return "user"
        case .system:                return "system"
        case .coordinator:           return "coordinator"
        case .agent(let domain):     return "agent:\(domain)"
        }
    }

    var requiresReasoning: Bool {
        switch self {
        case .user, .system:       return false
        case .coordinator, .agent: return true
        }
    }
}

enum EventLogError: Error, CustomStringConvertible, Equatable {
    case reasoningRequired(actor: String)
    case payloadEncodeFailed(reason: String)

    var description: String {
        switch self {
        case .reasoningRequired(let a):
            return "events: actor '\(a)' requires non-nil reasoning per hard reject #11"
        case .payloadEncodeFailed(let r):
            return "events: payload encode failed: \(r)"
        }
    }
}

struct EventRecord: Equatable, Sendable {
    let eventID: EventID
    let createdAt: Date
    let actor: EventActor
    let kind: String
    let domain: String?
    let instrumentID: InstrumentID?
    let commitmentID: CommitmentID?
    let text: String?
    let payloadJSON: String?
    let source: String?
    let reasoning: String?
}

enum EventLog {

    /// Append one row to `events`. Returns the generated event Id. Caller
    /// supplies the open `Database` handle so this can sit inside a larger
    /// `db.write { }` transaction.
    @discardableResult
    static func append(
        actor: EventActor,
        kind: String,
        text: String? = nil,
        domain: String? = nil,
        instrumentID: InstrumentID? = nil,
        commitmentID: CommitmentID? = nil,
        payloadJSON: String? = nil,
        source: String? = nil,
        reasoning: String? = nil,
        at now: Date = Date(),
        eventID: EventID = ULID.generate(),
        in db: Database
    ) throws -> EventID {
        if actor.requiresReasoning, (reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EventLogError.reasoningRequired(actor: actor.sqlValue)
        }
        let createdMs = Int64(now.timeIntervalSince1970 * 1000)
        try db.execute(
            sql: """
                INSERT INTO events (
                    event_id, created_at, actor, kind, domain, instrument_id,
                    commitment_id, text, payload_json, source, reasoning
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                eventID,
                createdMs,
                actor.sqlValue,
                kind,
                domain,
                instrumentID,
                commitmentID,
                text,
                payloadJSON,
                source,
                reasoning
            ]
        )
        return eventID
    }

    /// Convenience: encode a Codable payload to JSON before insert. Errors
    /// surface as `payloadEncodeFailed` — the agent never sees a raw
    /// `EncodingError`.
    @discardableResult
    static func append<P: Encodable>(
        actor: EventActor,
        kind: String,
        payload: P,
        text: String? = nil,
        domain: String? = nil,
        instrumentID: InstrumentID? = nil,
        commitmentID: CommitmentID? = nil,
        source: String? = nil,
        reasoning: String? = nil,
        at now: Date = Date(),
        eventID: EventID = ULID.generate(),
        in db: Database
    ) throws -> EventID {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json: String
        do {
            let data = try encoder.encode(payload)
            guard let s = String(data: data, encoding: .utf8) else {
                throw EventLogError.payloadEncodeFailed(reason: "UTF-8 encode failed")
            }
            json = s
        } catch let e as EventLogError {
            throw e
        } catch {
            throw EventLogError.payloadEncodeFailed(reason: String(describing: error))
        }
        return try append(
            actor: actor,
            kind: kind,
            text: text,
            domain: domain,
            instrumentID: instrumentID,
            commitmentID: commitmentID,
            payloadJSON: json,
            source: source,
            reasoning: reasoning,
            at: now,
            eventID: eventID,
            in: db
        )
    }
}
