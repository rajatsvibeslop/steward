//
//  FoundationModelsSession.swift
//  Steward — Track B
//
//  Real-LLM conformance to `LLMSession`. Entire file body wrapped in
//  `#if canImport(FoundationModels)` so the Xcode 16.3 build skips it
//  cleanly until the iOS 26 SDK is installed.
//
//  Hard rule (addendum §4 #20): `import FoundationModels` is allowed
//  ONLY in this file and `LLMResolver.swift`. Adding it anywhere else
//  recouples the architecture to a single provider and breaks the
//  16.3-toolchain build the user is on tonight.
//
//  The Foundation Models framework auto-loops tool calls inside
//  `respond(to:)` — we never manually loop (§4 #7).
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
public struct FoundationModelsSessionFactory: LLMSessionFactory {
    public let backendKind: LLMBackendKind = .foundationModels

    public init() {}

    public func makeSession(
        systemPrompt: String,
        tools: [any LLMTool],
        temperature: Double
    ) async throws -> any LLMSession {
        return try await FoundationModelsSession(
            systemPrompt: systemPrompt,
            tools: tools,
            temperature: temperature
        )
    }
}

/// Bridges Steward's provider-agnostic `LLMTool` (JSON-string vocabulary)
/// to the FoundationModels framework's typed `Tool` conformance. The
/// framework parses + dispatches; we just hand it a wrapped invoke().
@available(iOS 26.0, *)
private struct FMToolAdapter: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let wrapped: any LLMTool

    var name: String { wrapped.id }
    var description: String { wrapped.description }

    func call(arguments: GeneratedContent) async throws -> String {
        let argsJSON = arguments.jsonString
        return try await wrapped.invoke(argsJSON: argsJSON)
    }
}

@available(iOS 26.0, *)
public actor FoundationModelsSession: LLMSession {
    private var session: LanguageModelSession
    private let toolMap: [String: any LLMTool]
    private let backendKind: LLMBackendKind = .foundationModels

    public init(
        systemPrompt: String,
        tools: [any LLMTool],
        temperature: Double
    ) async throws {
        let adapters = tools.map { FMToolAdapter(wrapped: $0) }
        self.toolMap = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })

        // Construct a fresh per-turn session (addendum §3 FM bullet:
        // "Wrap each turn in a fresh LanguageModelSession to bound KV cache").
        self.session = LanguageModelSession(
            instructions: systemPrompt,
            tools: adapters,
            generationOptions: GenerationOptions(temperature: temperature)
        )
    }

    public func respond(to userMessage: String) async throws -> LLMResponse {
        // Foundation Models auto-loops tool calls within this single call.
        // We never manually loop (§4 hard reject #7). On return, the
        // transcript carries every tool invocation the framework ran.
        let result = try await session.respond(to: userMessage)

        let invocations = result.transcript.toolInvocations.map { call in
            LLMToolInvocation(
                toolID: call.toolName,
                argsJSON: call.argumentsJSON,
                resultJSON: call.outputJSON,
                executedAt: call.timestamp
            )
        }

        return LLMResponse(
            text: result.content,
            toolInvocations: invocations,
            backendKind: backendKind
        )
    }

    public func reset() async {
        // Recreate the underlying session. The instructions and tools are
        // captured in this actor's init args via the adapters dictionary,
        // but we can't reconstruct without storing them. KV-cache bounding
        // is the goal — for v1 the agent loop creates a fresh
        // FoundationModelsSession per user turn anyway, so reset() is a
        // no-op here.
    }
}

#endif // canImport(FoundationModels)
