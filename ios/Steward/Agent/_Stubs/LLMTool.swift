//
//  LLMTool.swift
//  Steward — Agent/_Stubs/
//
//  DELETE AT MERGE — Pod B owns canonical per addendum §1.10.
//
//  Track D defines this stub so EventKit / Notification tool surfaces compile
//  against a stable shape ahead of Pod B's `LLMSession` / `LLMResolver` work.
//  Surface MUST match addendum §1.10 verbatim so Pod B's canonical file is a
//  drop-in replacement at merge — no call-site changes anywhere in the tree.
//
//  HARD REJECT #20: `import FoundationModels` is FORBIDDEN here. This stub is
//  plain Foundation so the build stays green on Xcode 16.3 / iOS 18.4 SDK
//  until Pod B's gated `FoundationModelsSession.swift` lands behind
//  `#if canImport(FoundationModels)`.
//

import Foundation

/// Protocol every tool conforms to. JSON in / JSON out.
///
/// Implementations are pure Swift actors / structs — they never see a
/// `LanguageModelSession`, never see permission UI state, and never compose
/// notification bodies. The session's tool dispatcher handles serialization.
protocol LLMTool: Sendable {
    var id: String { get }
    var description: String { get }
    var jsonSchemaForArgs: String { get }
    func invoke(argsJSON: String) async throws -> String
}

/// Structured tool error surface. Foundation Models receives errors as part of
/// the tool result vocabulary — never as Swift `throw`s that bubble out of
/// `respond(to:)` (which would terminate the agent loop entirely).
struct ToolError: Error, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case argumentsInvalid
        case permissionDenied
        case capExceeded
        case notFound
        case backendUnavailable
        case internalFailure
    }
    let kind: Kind
    let message: String
    let hint: String?

    init(kind: Kind, message: String, hint: String? = nil) {
        self.kind = kind
        self.message = message
        self.hint = hint
    }
}
