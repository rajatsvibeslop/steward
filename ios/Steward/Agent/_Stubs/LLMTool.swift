//
//  LLMTool.swift  (Track C stub — Agent/_Stubs/)
//
//  DELETE AT MERGE — Pod B owns canonical per addendum §1.10.
//  Surface must match Pod B's `Agent/LLMTool.swift` exactly:
//    `id`, `description`, `jsonSchemaForArgs`, `invoke(argsJSON:) async throws -> String`.
//  At merge, Pod B's file wins; this stub is deleted; tool catalog
//  compiles unchanged because the surface matches.
//
//  Provider-agnostic tool protocol per addendum §1.10. Tools register a JSON
//  schema for their args and an `invoke(argsJSON:) -> String` that does the
//  work. `FoundationModelsSession` (Pod B, when iOS 26 SDK lands) bridges
//  this to the @Generable / Tool conformance internally; `MockLLMSession`
//  invokes by toolId pattern match.
//
//  HARD REJECT #20: only `FoundationModelsSession.swift` and `LLMResolver.swift`
//  may `import FoundationModels`. This file is gateway-clean.
//

import Foundation

/// One callable surface exposed to the language model. Implementations live
/// in `Tools/Catalog/*Tools.swift`. Each tool produces a JSON string result
/// that the LLM provider serializes back into the transcript.
public protocol LLMTool: Sendable {
    /// Stable identifier; corresponds to `ToolId.rawValue`.
    var id: String { get }

    /// One-sentence human-readable description for the tool catalog segment
    /// of the system prompt. No example outputs (hard reject #6 spirit:
    /// templates own copy).
    var description: String { get }

    /// JSON schema describing the args object the LLM should produce. Schema
    /// format is plain JSON-Schema-draft-07 subset; FoundationModelsSession
    /// bridges this to `@Generable` at the framework boundary.
    var jsonSchemaForArgs: String { get }

    /// Invoke the tool with the JSON-encoded args. Returns a JSON-encoded
    /// result. THROWING is the typed failure path; the agent loop converts
    /// thrown errors into a structured `tool_error` shape so the LLM can route.
    func invoke(argsJSON: String) async throws -> String
}

/// Typed wrapper around a JSON-encoded tool result. Tool implementations
/// produce these; the LLM provider serializes them to the transcript.
public struct LLMToolError: Error, Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let details: [String: String]?

    public init(code: String, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// JSON encode/decode helpers used by every tool. Centralized so all tool
/// args use the same date strategy (ISO-8601) — the LLM is going to emit
/// ISO strings either way, and matching here avoids a thousand bespoke
/// `dateDecodingStrategy` lines.
public enum ToolJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw LLMToolError(code: "encode_failed", message: "UTF-8 encode failed")
        }
        return s
    }

    public static func decode<T: Decodable>(_ type: T.Type, from argsJSON: String) throws -> T {
        guard let data = argsJSON.data(using: .utf8) else {
            throw LLMToolError(code: "invalid_args", message: "args JSON not UTF-8")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LLMToolError(
                code: "invalid_args",
                message: "args decode failed: \(error)"
            )
        }
    }
}
