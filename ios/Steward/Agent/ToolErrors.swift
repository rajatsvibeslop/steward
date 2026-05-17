//
//  ToolErrors.swift
//  Steward
//
//  Cross-pod tool infrastructure: a structured `LLMToolError` plus a
//  small `ToolJSON` namespace for deterministic, sortedKeys JSON encode /
//  decode of tool args + results.
//
//  Pod C's leaf tools throw `LLMToolError(code:, message:)` for any
//  caller-facing failure; Pod B's AgentLoop catches these and forwards
//  the structured payload back to the LLM as a tool-result. Production
//  paths must NEVER use `fatalError` / `preconditionFailure` (hard
//  reject #3) — every tool failure becomes a typed error here.
//

import Foundation

/// Caller-facing tool error. Has a stable `code` so the coordinator LLM
/// can branch deterministically, plus a free-form `message` for the
/// audit log and human-readable surfaces.
///
/// `code` values are conventionally snake_case and stable across
/// releases; PodC reviewers grep for these in test files.
public struct LLMToolError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String {
        "LLMToolError(\(code)): \(message)"
    }
}

// MARK: - ToolError (non-LLM-visible failures)

/// Categorical error thrown by Pod D's EventKit / Notification tools
/// when an `invoke(...)` call surfaces a failure that should NOT be fed
/// back to the LLM as a normal tool result (e.g. malformed arg JSON,
/// permission revocations). Pod D's UI surfaces these directly; Pod B's
/// AgentLoop swallows them into a structured tool-result string.
public enum ToolErrorKind: String, Sendable, Equatable, Hashable {
    /// Args couldn't be parsed (malformed JSON, missing required keys,
    /// unparseable RRULE, etc.).
    case argumentsInvalid
    /// Caller tried to invoke a tool whose backing permission has been
    /// revoked (EventKit access, notification authorization, etc.).
    case permissionRequired
    /// Backend store is unreachable (EKEventStore returned nil, etc.).
    case backendUnavailable
    /// Generic dispatch / wiring failure.
    case dispatch
}

public struct ToolError: Error, Equatable, Sendable, CustomStringConvertible {
    public let kind: ToolErrorKind
    public let message: String
    /// Human-readable next-step hint shown alongside `message` when
    /// surfaced through Settings → "Recent agent actions".
    public let hint: String?

    public init(kind: ToolErrorKind, message: String, hint: String? = nil) {
        self.kind = kind
        self.message = message
        self.hint = hint
    }

    public var description: String {
        if let h = hint, !h.isEmpty {
            return "ToolError(\(kind.rawValue)): \(message) — \(h)"
        }
        return "ToolError(\(kind.rawValue)): \(message)"
    }
}

/// Deterministic JSON helpers shared across every leaf tool.
///
/// `sortedKeys` matters because (a) Pod C's tool-result snapshots in
/// tests compare strings, and (b) the audit log stores
/// `events.payload_json` verbatim — non-deterministic output would
/// thrash diffs and CSV mirrors for no reason.
public enum ToolJSON {

    /// Canonical encoder — sortedKeys + iso8601 dates. Exposed for the
    /// rare site that needs `Data` (e.g. nesting an already-encoded JSON
    /// blob into another field). New code should prefer `encode(_:)`.
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Canonical decoder — iso8601 dates.
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Encode a Codable value as a UTF-8 JSON string.
    /// Throws `LLMToolError(code: "encode_failed", ...)` on the (in
    /// practice, impossible) UTF-8 decode failure so leaf tools never
    /// surface a raw `EncodingError`.
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw LLMToolError(
                code: "encode_failed",
                message: "JSON encode succeeded but UTF-8 conversion did not"
            )
        }
        return s
    }

    /// Decode a Codable value from a UTF-8 JSON string. Throws
    /// `LLMToolError(code: "arguments_invalid", ...)` with the underlying
    /// reason on malformed input — tools surface this verbatim to the LLM.
    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw LLMToolError(
                code: "arguments_invalid",
                message: "argument string is not valid UTF-8"
            )
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LLMToolError(
                code: "arguments_invalid",
                message: "could not decode \(type): \(error)"
            )
        }
    }
}
