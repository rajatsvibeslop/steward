//
//  DomainTools.swift
//  Steward
//
//  Spec §8 domain management: create / list / update_prompt / archive.
//  Domain rows hold the role_prompt the coordinator splices into the
//  domain-agent system prompt and the tool_scope_json the agent loop
//  enforces.
//

import Foundation
import GRDB

// MARK: - domain.create

struct DomainCreateArgs: Codable, Equatable, Sendable {
    let domain: String          // e.g. "money", "health"
    let displayName: String     // e.g. "Money agent"
    let rolePrompt: String
    /// Optional tool_scope override; defaults to `ToolScope.domain(domain)`
    /// (the typed convenience the agent loop will load).
    let toolScopeJSON: String?
    let defaultQuietHours: String?
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case domain
        case displayName = "display_name"
        case rolePrompt = "role_prompt"
        case toolScopeJSON = "tool_scope_json"
        case defaultQuietHours = "default_quiet_hours"
        case reasoning
        case actor
    }
}

struct DomainCreateResult: Codable, Equatable, Sendable {
    let domain: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case domain
        case createdAt = "created_at"
    }
}

struct DomainCreateTool: LLMTool {
    let id: String = ToolID.domainCreate.rawValue
    let description: String = "Spawn a new life-team domain. Persists role_prompt + default tool scope."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["domain", "display_name", "role_prompt", "reasoning", "actor"],
      "properties": {
        "domain": {"type": "string"},
        "display_name": {"type": "string"},
        "role_prompt": {"type": "string"},
        "tool_scope_json": {"type": ["string", "null"]},
        "default_quiet_hours": {"type": ["string", "null"]},
        "reasoning": {"type": "string"},
        "actor": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let auditLog: AuditLog
    let now: @Sendable () -> Date
    init(provider: DatabaseProvider = .shared,
         auditLog: AuditLog = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.auditLog = auditLog
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(DomainCreateArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let nowMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        let toolScopeJSON: String
        if let s = args.toolScopeJSON {
            toolScopeJSON = s
        } else {
            // Serialize the convenience default. We don't need to roundtrip
            // through Codable for the typed scope; just stash the JSON.
            let scope = ToolScope.domain(args.domain)
            let data = try ToolJSON.encoder.encode(scope)
            toolScopeJSON = String(data: data, encoding: .utf8) ?? "{}"
        }
        let db = try await provider.database()
        try await db.write { dbase in
            // PK collision = idempotent failure; surface as typed error.
            let exists = try Int.fetchOne(
                dbase,
                sql: "SELECT COUNT(*) FROM domains WHERE domain = ?",
                arguments: [args.domain]
            ) ?? 0
            if exists > 0 {
                throw LLMToolError(
                    code: "domain_already_exists",
                    message: "domain '\(args.domain)' already exists"
                )
            }
            try dbase.execute(
                sql: """
                    INSERT INTO domains (domain, display_name, role_prompt, tool_scope_json,
                                         default_quiet_hours, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    args.domain,
                    args.displayName,
                    args.rolePrompt,
                    toolScopeJSON,
                    args.defaultQuietHours,
                    nowMs
                ]
            )
            try EventLog.append(
                actor: actor,
                kind: "domain_create",
                text: args.displayName,
                domain: args.domain,
                payloadJSON: toolScopeJSON,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }

        // Track-D parity audit row so Settings → Recent actions can offer
        // one-tap undo. Inverse of domain.create is unarchive of the row
        // (we re-archive it on undo to hide it from the LLM tool surface).
        let action = TurnAction(
            turnID: TurnID.generate(),
            toolID: .domainCreate,
            actor: ActorRef.from(actor),
            executedAt: timestamp,
            reasoning: args.reasoning,
            inverse: .unarchiveDomain(domain: args.domain)
        )
        do {
            _ = try await auditLog.recordAgentAction(
                action,
                text: args.displayName,
                domain: args.domain,
                source: "tool:domain.create"
            )
        } catch {
            // Audit failure mustn't fail the primary tool result.
        }

        return try ToolJSON.encode(DomainCreateResult(domain: args.domain, createdAt: timestamp))
    }
}

// MARK: - domain.list

struct DomainListArgs: Codable, Equatable, Sendable {
    let includeArchived: Bool?

    enum CodingKeys: String, CodingKey {
        case includeArchived = "include_archived"
    }
}

struct DomainListItem: Codable, Equatable, Sendable {
    let domain: String
    let displayName: String
    let rolePrompt: String
    let createdAt: Date
    let archived: Bool

    enum CodingKeys: String, CodingKey {
        case domain
        case displayName = "display_name"
        case rolePrompt = "role_prompt"
        case createdAt = "created_at"
        case archived
    }
}

struct DomainListResult: Codable, Equatable, Sendable {
    let items: [DomainListItem]
}

struct DomainListTool: LLMTool {
    let id: String = ToolID.domainList.rawValue
    let description: String = "List domains (life teams). Archived hidden by default."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "properties": {
        "include_archived": {"type": ["boolean", "null"]}
      }
    }
    """

    let provider: DatabaseProvider
    init(provider: DatabaseProvider = .shared) { self.provider = provider }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(DomainListArgs.self, from: argsJSON)
        let includeArchived = args.includeArchived ?? false
        let db = try await provider.database()
        let items: [DomainListItem] = try await db.read { dbase in
            var sql = """
                SELECT domain, display_name, role_prompt, created_at, archived_at
                FROM domains
            """
            if !includeArchived {
                sql += " WHERE archived_at IS NULL"
            }
            sql += " ORDER BY created_at ASC"
            let rows = try Row.fetchAll(dbase, sql: sql)
            return rows.map { row in
                DomainListItem(
                    domain: row["domain"],
                    displayName: row["display_name"],
                    rolePrompt: row["role_prompt"],
                    createdAt: Date(timeIntervalSince1970: Double(row["created_at"] as Int64) / 1000),
                    archived: (row["archived_at"] as Int64?) != nil
                )
            }
        }
        return try ToolJSON.encode(DomainListResult(items: items))
    }
}

// MARK: - domain.update_prompt

struct DomainUpdatePromptArgs: Codable, Equatable, Sendable {
    let domain: String
    let newRolePrompt: String
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case domain
        case newRolePrompt = "new_role_prompt"
        case reasoning
        case actor
    }
}

struct DomainUpdatePromptResult: Codable, Equatable, Sendable {
    let domain: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case domain
        case updatedAt = "updated_at"
    }
}

struct DomainUpdatePromptTool: LLMTool {
    let id: String = ToolID.domainUpdatePrompt.rawValue
    let description: String = "Replace a domain's role_prompt. Used when user says 'health agent, never moralize'."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["domain", "new_role_prompt", "reasoning", "actor"],
      "properties": {
        "domain": {"type": "string"},
        "new_role_prompt": {"type": "string"},
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
        let args = try ToolJSON.decode(DomainUpdatePromptArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let db = try await provider.database()
        try await db.write { dbase in
            try dbase.execute(
                sql: "UPDATE domains SET role_prompt = ? WHERE domain = ?",
                arguments: [args.newRolePrompt, args.domain]
            )
            try EventLog.append(
                actor: actor,
                kind: "domain_update_prompt",
                text: args.newRolePrompt,
                domain: args.domain,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(DomainUpdatePromptResult(domain: args.domain, updatedAt: timestamp))
    }
}

// MARK: - domain.archive

struct DomainArchiveArgs: Codable, Equatable, Sendable {
    let domain: String
    let reason: String
    let reasoning: String
    let actor: String
}

struct DomainArchiveResult: Codable, Equatable, Sendable {
    let domain: String
    let archivedAt: Date

    enum CodingKeys: String, CodingKey {
        case domain
        case archivedAt = "archived_at"
    }
}

struct DomainArchiveTool: LLMTool {
    let id: String = ToolID.domainArchive.rawValue
    let description: String = "Archive a domain. Reversible via undo."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["domain", "reason", "reasoning", "actor"],
      "properties": {
        "domain": {"type": "string"},
        "reason": {"type": "string"},
        "reasoning": {"type": "string"},
        "actor": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let auditLog: AuditLog
    let now: @Sendable () -> Date
    init(provider: DatabaseProvider = .shared,
         auditLog: AuditLog = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.auditLog = auditLog
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(DomainArchiveArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()
        let nowMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        let db = try await provider.database()
        try await db.write { dbase in
            try dbase.execute(
                sql: "UPDATE domains SET archived_at = ? WHERE domain = ?",
                arguments: [nowMs, args.domain]
            )
            try EventLog.append(
                actor: actor,
                kind: "domain_archive",
                text: args.reason,
                domain: args.domain,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }

        // Audit row + undo handle.
        let action = TurnAction(
            turnID: TurnID.generate(),
            toolID: .domainArchive,
            actor: ActorRef.from(actor),
            executedAt: timestamp,
            reasoning: args.reasoning,
            inverse: .archiveDomain(domain: args.domain, archivedAt: timestamp)
        )
        do {
            _ = try await auditLog.recordAgentAction(
                action,
                text: args.reason,
                domain: args.domain,
                source: "tool:domain.archive"
            )
        } catch {
            // Audit failure mustn't fail the primary tool result.
        }

        return try ToolJSON.encode(DomainArchiveResult(domain: args.domain, archivedAt: timestamp))
    }
}
