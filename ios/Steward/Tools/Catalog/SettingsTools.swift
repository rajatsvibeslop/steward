//
//  SettingsTools.swift
//  Steward
//
//  Spec §8 settings/safety tools. All three mutate via SettingsStore.shared
//  (hard reject #16). No raw SQL on `settings` lives outside SettingsStore.
//

import Foundation

// MARK: - mercy_mode.engage

struct MercyModeEngageArgs: Codable, Equatable, Sendable {
    let untilWhen: Date
    let reason: String
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case untilWhen = "until_when"
        case reason
        case reasoning
        case actor
    }
}

struct MercyModeEngageResult: Codable, Equatable, Sendable {
    let mercyModeUntil: Date
    let engagedAt: Date

    enum CodingKeys: String, CodingKey {
        case mercyModeUntil = "mercy_mode_until"
        case engagedAt = "engaged_at"
    }
}

struct MercyModeEngageTool: LLMTool {
    let id: String = ToolID.mercyModeEngage.rawValue
    let description: String = "Engage mercy mode until a date. Softens nudges, prefers smallest re-entry actions."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["until_when", "reason", "reasoning", "actor"],
      "properties": {
        "until_when": {"type": "string", "format": "date-time"},
        "reason": {"type": "string"},
        "reasoning": {"type": "string"},
        "actor": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let settings: SettingsStore
    let now: @Sendable () -> Date
    init(provider: DatabaseProvider = .shared,
         settings: SettingsStore = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.settings = settings
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(MercyModeEngageArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()

        // Mutate settings through the actor — hard reject #16.
        let updated = try await settings.update { s in
            s.mercyModeUntil = args.untilWhen
        }

        // Log the agent action.
        let db = try await provider.database()
        _ = try await db.write { dbase in
            try EventLog.append(
                actor: actor,
                kind: "mercy_mode_engage",
                payload: ["until": ISO8601DateFormatter().string(from: args.untilWhen)],
                text: args.reason,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }

        return try ToolJSON.encode(MercyModeEngageResult(
            mercyModeUntil: updated.mercyModeUntil ?? args.untilWhen,
            engagedAt: timestamp
        ))
    }
}

// MARK: - pause.engage

struct PauseEngageArgs: Codable, Equatable, Sendable {
    let untilWhen: Date
    let reason: String
    let reasoning: String
    let actor: String

    enum CodingKeys: String, CodingKey {
        case untilWhen = "until_when"
        case reason
        case reasoning
        case actor
    }
}

struct PauseEngageResult: Codable, Equatable, Sendable {
    let pauseUntil: Date
    let engagedAt: Date

    enum CodingKeys: String, CodingKey {
        case pauseUntil = "pause_until"
        case engagedAt = "engaged_at"
    }
}

struct PauseEngageTool: LLMTool {
    let id: String = ToolID.pauseEngage.rawValue
    let description: String = "Pause non-critical notifications until a date."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["until_when", "reason", "reasoning", "actor"],
      "properties": {
        "until_when": {"type": "string", "format": "date-time"},
        "reason": {"type": "string"},
        "reasoning": {"type": "string"},
        "actor": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let settings: SettingsStore
    let now: @Sendable () -> Date
    init(provider: DatabaseProvider = .shared,
         settings: SettingsStore = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.settings = settings
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(PauseEngageArgs.self, from: argsJSON)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()

        let updated = try await settings.update { s in
            s.pauseUntil = args.untilWhen
        }

        let db = try await provider.database()
        _ = try await db.write { dbase in
            try EventLog.append(
                actor: actor,
                kind: "pause_engage",
                payload: ["until": ISO8601DateFormatter().string(from: args.untilWhen)],
                text: args.reason,
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }

        return try ToolJSON.encode(PauseEngageResult(
            pauseUntil: updated.pauseUntil ?? args.untilWhen,
            engagedAt: timestamp
        ))
    }
}

// MARK: - quiet_hours.set

struct QuietHoursSetArgs: Codable, Equatable, Sendable {
    /// "HH:mm" wall-clock local time.
    let start: String
    let end: String
    let reasoning: String
    let actor: String
}

struct QuietHoursSetResult: Codable, Equatable, Sendable {
    let start: String
    let end: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case updatedAt = "updated_at"
    }
}

struct QuietHoursSetTool: LLMTool {
    let id: String = ToolID.quietHoursSet.rawValue
    let description: String = "Set the user's quiet hours window. Format: HH:mm local."
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["start", "end", "reasoning", "actor"],
      "properties": {
        "start": {"type": "string", "pattern": "^[0-2][0-9]:[0-5][0-9]$"},
        "end": {"type": "string", "pattern": "^[0-2][0-9]:[0-5][0-9]$"},
        "reasoning": {"type": "string"},
        "actor": {"type": "string"}
      }
    }
    """

    let provider: DatabaseProvider
    let settings: SettingsStore
    let now: @Sendable () -> Date
    init(provider: DatabaseProvider = .shared,
         settings: SettingsStore = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.settings = settings
        self.now = now
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(QuietHoursSetArgs.self, from: argsJSON)
        try Self.validateHHMM(args.start)
        try Self.validateHHMM(args.end)
        let actor = try EventTools.parseActor(args.actor)
        let timestamp = now()

        _ = try await settings.update { s in
            s.quietHours.start = args.start
            s.quietHours.end = args.end
        }

        let db = try await provider.database()
        _ = try await db.write { dbase in
            try EventLog.append(
                actor: actor,
                kind: "quiet_hours_set",
                payload: ["start": args.start, "end": args.end],
                source: "tool",
                reasoning: args.reasoning,
                at: timestamp,
                in: dbase
            )
        }
        return try ToolJSON.encode(QuietHoursSetResult(
            start: args.start,
            end: args.end,
            updatedAt: timestamp
        ))
    }

    private static func validateHHMM(_ s: String) throws {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else {
            throw LLMToolError(
                code: "invalid_hh_mm",
                message: "expected HH:mm 24-hour format, got '\(s)'"
            )
        }
    }
}
