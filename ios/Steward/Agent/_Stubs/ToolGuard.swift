//
//  ToolGuard.swift  (Track C stub — Agent/_Stubs/)
//
//  DELETE AT MERGE — Pod B owns canonical per addendum §1.8.
//  Surface (ToolGuard.validate, ToolGuardError) must match Pod B's
//  `Agent/ToolGuard.swift`. At merge: Pod B's file wins; this stub is
//  deleted in the merge commit.
//
//  Validates / rewrites tool args before dispatch. Returns the (possibly
//  rewritten) args JSON so the tool implementation always sees a canonical
//  shape — domain-pinned, whitelist-respecting, scope-allowed.
//

import Foundation

enum ToolGuardError: Error, Codable, Equatable, Sendable {
    case toolNotAllowed(ToolId)
    case fixedArgConflict(arg: String, expected: String, got: String)
    case valueNotAllowed(arg: String, got: String, allowed: [String])
    case argsNotObject

    var llmFacing: LLMToolError {
        switch self {
        case .toolNotAllowed(let id):
            return LLMToolError(
                code: "tool_not_allowed",
                message: "agent scope does not allow \(id.rawValue)"
            )
        case .fixedArgConflict(let arg, let expected, let got):
            return LLMToolError(
                code: "fixed_arg_conflict",
                message: "arg '\(arg)' is pinned to '\(expected)' for this scope but received '\(got)'"
            )
        case .valueNotAllowed(let arg, let got, let allowed):
            return LLMToolError(
                code: "value_not_allowed",
                message: "arg '\(arg)' = '\(got)' not in whitelist",
                details: ["allowed": allowed.joined(separator: ",")]
            )
        case .argsNotObject:
            return LLMToolError(
                code: "invalid_args",
                message: "args JSON must be an object"
            )
        }
    }
}

enum ToolGuard {

    /// Validate `argsJSON` against `scope`. Pinned args are silently
    /// overwritten; whitelist violations and disallowed tools throw.
    /// Returns the canonical (possibly rewritten) args JSON.
    static func validate(
        _ toolId: ToolId,
        argsJSON: String,
        scope: ToolScope
    ) throws -> String {
        guard scope.allowedTools.contains(toolId) else {
            throw ToolGuardError.toolNotAllowed(toolId)
        }
        let constraints = scope.argConstraints[toolId] ?? .none

        // Parse, mutate, re-encode. We only handle JSON objects at the top.
        guard let data = argsJSON.data(using: .utf8),
              var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolGuardError.argsNotObject
        }

        // Fixed args: overwrite. Surface conflict only when the LLM
        // explicitly set a different value than the pin (catches obvious
        // attempts at scope evasion).
        for (k, pinned) in constraints.fixedArgs {
            let pinnedString = anyToString(pinned)
            if let existing = obj[k] {
                let existingString = String(describing: existing)
                if existingString != pinnedString {
                    throw ToolGuardError.fixedArgConflict(
                        arg: k,
                        expected: pinnedString,
                        got: existingString
                    )
                }
            }
            obj[k] = anyToJSONValue(pinned)
        }

        // Whitelists.
        for (k, allowed) in constraints.allowedValues {
            guard let value = obj[k] else { continue }
            let allowedStrings = allowed.map(anyToString)
            let valueString = String(describing: value)
            if !allowedStrings.contains(valueString) {
                throw ToolGuardError.valueNotAllowed(
                    arg: k,
                    got: valueString,
                    allowed: allowedStrings
                )
            }
        }

        let rewritten = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        guard let str = String(data: rewritten, encoding: .utf8) else {
            throw ToolGuardError.argsNotObject
        }
        return str
    }

    // MARK: - Helpers

    private static func anyToString(_ v: AnyCodable) -> String {
        switch v {
        case .string(let s): return s
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .bool(let b):   return String(b)
        case .null:          return "null"
        }
    }

    private static func anyToJSONValue(_ v: AnyCodable) -> Any {
        switch v {
        case .string(let s): return s
        case .int(let i):    return i
        case .double(let d): return d
        case .bool(let b):   return b
        case .null:          return NSNull()
        }
    }
}
