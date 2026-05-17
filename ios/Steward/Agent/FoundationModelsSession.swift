//
//  FoundationModelsSession.swift
//  Steward
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

/// Out-of-band sink for `PermissionRequiredSignal` / `HealthPermissionRequiredSignal`
/// thrown inside a tool's `invoke(argsJSON:)`. The FoundationModels framework
/// owns the auto-loop and may swallow tool-call errors back into the model's
/// transcript. We can't rely on a `throw` from the adapter to propagate up
/// through `session.respond(to:)` cleanly. So the adapter writes the signal
/// here before re-throwing, and `FoundationModelsSession.respond` checks the
/// sink after the framework call returns — if a permission signal was
/// captured, it overrides the response and re-throws so the chat UI's host
/// catch arms fire (addendum §1.9 / HARD REJECT #19).
///
/// One sink per `FoundationModelsSession` instance (i.e. one per user turn).
/// First-wins: only the first signal in a turn is propagated, since the
/// inline-grant flow can only resolve one scope at a time anyway.
@available(iOS 26.0, *)
actor PermissionSignalSink {
    private var captured: Error?

    func record(_ error: Error) {
        if captured == nil { captured = error }
    }

    func consume() -> Error? {
        let result = captured
        captured = nil
        return result
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
    let sink: PermissionSignalSink

    var name: String { wrapped.id }
    var description: String { wrapped.description }

    func call(arguments: GeneratedContent) async throws -> String {
        let argsJSON = arguments.jsonString
        do {
            return try await wrapped.invoke(argsJSON: argsJSON)
        } catch let signal as PermissionRequiredSignal {
            let enriched = PermissionRequiredSignal(
                scope: signal.scope,
                pendingToolID: signal.pendingToolID ?? wrapped.id,
                pendingArgsJSON: signal.pendingArgsJSON ?? argsJSON
            )
            await sink.record(enriched)
            throw enriched
        } catch let signal as HealthPermissionRequiredSignal {
            let enriched = HealthPermissionRequiredSignal(
                scope: signal.scope,
                pendingToolID: signal.pendingToolID ?? wrapped.id,
                pendingArgsJSON: signal.pendingArgsJSON ?? argsJSON
            )
            await sink.record(enriched)
            throw enriched
        }
    }
}

@available(iOS 26.0, *)
public actor FoundationModelsSession: LLMSession {
    private var session: LanguageModelSession
    private let toolMap: [String: any LLMTool]
    private let backendKind: LLMBackendKind = .foundationModels
    private let permissionSink: PermissionSignalSink

    public init(
        systemPrompt: String,
        tools: [any LLMTool],
        temperature: Double
    ) async throws {
        let sink = PermissionSignalSink()
        self.permissionSink = sink
        let adapters = tools.map { FMToolAdapter(wrapped: $0, sink: sink) }
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
        //
        // A tool that throws `PermissionRequiredSignal` /
        // `HealthPermissionRequiredSignal` may have its error swallowed by
        // the framework auto-loop (the framework hands the error back to the
        // model so it can route around). We don't want that: addendum §1.9
        // says the UI host must catch the signal directly. The adapter wrote
        // the signal to `permissionSink` on its way through — consult the
        // sink BEFORE returning, even on the success path, and rethrow if
        // present. On the failure path, prefer the captured signal over the
        // framework's wrapped error (more actionable type for the UI catch
        // arms in `ChatViewModel.send`).
        do {
            let result = try await session.respond(to: userMessage)
            if let pending = await permissionSink.consume() {
                throw pending
            }
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
        } catch {
            if let pending = await permissionSink.consume() {
                throw pending
            }
            throw error
        }
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
