//
//  DomainStore.swift
//  Steward
//
//  Serialized read surface over the `domains` table. Used by:
//   - the UI (Today section headers, Settings Life Teams list, Chat domain
//     bubble rendering)
//   - `DBDomainAgentResolver`, which AgentLoop calls to look up the
//     active `DomainAgent` for a hand-off
//
//  Writes for renames / role-prompt edits / archive flow through the existing
//  tool-catalog tools (`domain.update_prompt`, `domain.archive`) so audit-log
//  reasoning + InverseAction wiring stay consistent with everything else. The
//  store only exposes reads + a thin update helper that goes through the
//  tools.
//

import Foundation
import GRDB

/// A row from the `domains` table, decoded into Swift.
struct DomainRecord: Sendable, Equatable, Identifiable {
    let domain: String
    let displayName: String
    let rolePrompt: String
    let toolScopeJSON: String
    let defaultQuietHours: String?
    let createdAt: Date
    let archivedAt: Date?

    var id: String { domain }
    var isArchived: Bool { archivedAt != nil }
}

actor DomainStore {
    static let shared = DomainStore()

    private let provider: DatabaseProvider

    init(provider: DatabaseProvider = .shared) {
        self.provider = provider
    }

    /// All active domains (archived_at IS NULL), sorted by created_at desc.
    /// Matches Designer §3.4 ordering for the LIFE TEAMS list.
    func listActive() async throws -> [DomainRecord] {
        let queue = try await provider.database()
        return try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT domain, display_name, role_prompt, tool_scope_json,
                           default_quiet_hours, created_at, archived_at
                    FROM domains
                    WHERE archived_at IS NULL
                    ORDER BY created_at DESC
                """
            ).map(Self.decode(row:))
        }
    }

    /// One domain by primary key, or nil if missing.
    func get(domain: String) async throws -> DomainRecord? {
        let queue = try await provider.database()
        return try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT domain, display_name, role_prompt, tool_scope_json,
                           default_quiet_hours, created_at, archived_at
                    FROM domains
                    WHERE domain = ?
                """,
                arguments: [domain]
            )
            return row.map(Self.decode(row:))
        }
    }

    /// Update the display_name on a domain row. The audit-log entry is
    /// emitted as a `user`-actor event (not an agent) so it requires no
    /// reasoning per the events CHECK; the row is preserved so undo can
    /// roll back via a forthcoming `domain.update_name` inverse (v1.1).
    func rename(domain: String, to newDisplayName: String) async throws {
        let queue = try await provider.database()
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE domains SET display_name = ? WHERE domain = ?",
                arguments: [trimmed, domain]
            )
            try EventLog.append(
                actor: EventActor.user,
                kind: "domain_rename",
                domain: domain,
                payloadJSON: "{\"new_display_name\":\"\(Self.escapeJSON(trimmed))\"}",
                source: "settings_ui",
                in: db
            )
        }
    }

    // MARK: - Private

    private static func decode(row: Row) -> DomainRecord {
        let createdMs: Int64 = row["created_at"]
        let archivedMs: Int64? = row["archived_at"]
        return DomainRecord(
            domain: row["domain"],
            displayName: row["display_name"],
            rolePrompt: row["role_prompt"],
            toolScopeJSON: row["tool_scope_json"],
            defaultQuietHours: row["default_quiet_hours"],
            createdAt: Date(timeIntervalSince1970: Double(createdMs) / 1000),
            archivedAt: archivedMs.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            }
        )
    }

    private static func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - DomainAgentResolver conformance

/// DB-backed resolver AgentLoop calls during hand-offs. Reads the
/// active domains table and constructs a `DomainAgent` per row.
struct DBDomainAgentResolver: DomainAgentResolver {
    let store: DomainStore

    init(store: DomainStore = .shared) {
        self.store = store
    }

    func resolve(domain: String) async -> DomainAgent? {
        do {
            guard let record = try await store.get(domain: domain),
                  record.archivedAt == nil
            else { return nil }
            return DomainAgent(
                domain: record.domain,
                displayName: record.displayName,
                rolePrompt: record.rolePrompt
            )
        } catch {
            return nil
        }
    }

    func listActive() async -> [DomainSummary] {
        do {
            let rows = try await store.listActive()
            return rows.map { DomainSummary(domain: $0.domain, displayName: $0.displayName) }
        } catch {
            return []
        }
    }
}
