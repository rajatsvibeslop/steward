//
//  ChatViewModel.swift
//  Steward — Track E
//
//  Bridges the SwiftUI ChatView to the agent loop. Owns the in-memory
//  transcript and the per-turn lifecycle:
//   1. user sends → append optimistic user bubble + thinking placeholder
//   2. resolve `AgentLoopHost.shared` and call `loop.run(userMessage:)`
//   3. on return: drop placeholder, append assistant bubble + tool-call cards
//      derived from `CoordinatorResponse.toolInvocations`
//   4. on failure: drop placeholder, append a systemNote with a retry hook
//
//  The empty-state flag is computed from the persisted event log (no events
//  yet → render greeting + chips). The first user message hides the greeting
//  forever after (matches Designer §1.7).
//

import Foundation
import GRDB
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending: Bool = false
    @Published private(set) var hasAnyHistory: Bool = false
    @Published private(set) var hasAnyDomains: Bool = false
    @Published private(set) var backendKind: LLMBackendKind?
    @Published private(set) var lastError: String?

    /// The greeting bubble + chip pair displays iff this is true.
    var shouldShowEmptyState: Bool { !hasAnyHistory && !hasAnyDomains }

    /// Persistent placeholder picked once per cold launch from §1.5.
    let placeholderText: String

    private let provider: DatabaseProvider
    private let domainStore: DomainStore
    private let clock: @Sendable () -> Date

    init(
        provider: DatabaseProvider = .shared,
        domainStore: DomainStore = .shared,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.domainStore = domainStore
        self.clock = clock
        self.placeholderText = ChatViewModel.pickPlaceholder()
    }

    // MARK: - Loading state

    func loadInitialState() async {
        await refreshHistoryFlags()
        if backendKind == nil {
            if let ready = try? await AgentLoopHost.shared.ready() {
                backendKind = ready.backendKind
            }
        }
    }

    private func refreshHistoryFlags() async {
        let providerLocal = self.provider
        let storeLocal = self.domainStore
        let userEventCount: Int = await {
            do {
                let db = try await providerLocal.database()
                return try await db.read { dbase in
                    try Int.fetchOne(
                        dbase,
                        sql: "SELECT COUNT(*) FROM events WHERE actor = 'user'"
                    ) ?? 0
                }
            } catch {
                return 0
            }
        }()
        let domains: [DomainRecord] = (try? await storeLocal.listActive()) ?? []
        hasAnyHistory = userEventCount > 0
        hasAnyDomains = !domains.isEmpty
    }

    // MARK: - Sending

    /// User tapped send.
    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        // Optimistic user bubble + thinking placeholder.
        appendUserBubble(text: text)
        let thinkingID = appendThinkingPlaceholder()

        isSending = true
        lastError = nil
        // Once the user sends, the greeting/chips dismiss (one-shot UI).
        hasAnyHistory = true

        do {
            let ready = try await AgentLoopHost.shared.ready()
            backendKind = ready.backendKind
            let response = try await ready.loop.run(userMessage: text)
            removeMessage(id: thinkingID)
            appendCoordinatorReply(response: response)
            // Refresh domain knowledge — the turn may have spawned one via
            // `domain.create`; the chat surface should stop showing the
            // empty-state greeting on subsequent loads.
            await refreshHistoryFlags()
        } catch {
            removeMessage(id: thinkingID)
            let errorText = "Steward took too long. Saved your message — tap to retry."
            appendMessage(ChatMessage(
                id: UUID().uuidString,
                timestamp: clock(),
                body: .systemNote(text: errorText)
            ))
            lastError = String(describing: error)
        }
        isSending = false
    }

    /// User tapped "Walk me through it" chip — fill the input with the literal
    /// string but DO NOT auto-send (§1.7).
    func walkMeThroughItText() -> String { "walk me through it" }

    // MARK: - Mutators

    private func appendUserBubble(text: String) {
        appendMessage(ChatMessage(
            id: UUID().uuidString,
            timestamp: clock(),
            body: .user(text: text)
        ))
    }

    private func appendThinkingPlaceholder() -> String {
        let id = UUID().uuidString
        appendMessage(ChatMessage(
            id: id,
            timestamp: clock(),
            body: .thinkingCoordinator
        ))
        return id
    }

    private func appendCoordinatorReply(response: CoordinatorResponse) {
        let isStub: Bool = {
            switch response.backendKind {
            case .foundationModels: return false
            case .mock: return true
            }
        }()
        let bodyText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bodyText.isEmpty {
            appendMessage(ChatMessage(
                id: UUID().uuidString,
                timestamp: response.toolInvocations.last?.executedAt ?? clock(),
                body: .coordinator(text: bodyText, isStub: isStub)
            ))
        }
        // Tool-call cards inline, in invocation order.
        for inv in response.toolInvocations {
            let summary = ToolCallSummaryBuilder.build(
                invocation: inv,
                defaultActorLabel: "Steward",
                defaultDomainKey: nil,
                eventID: extractEventID(inv.resultJSON)
            )
            appendMessage(ChatMessage(
                id: UUID().uuidString,
                timestamp: inv.executedAt,
                body: .toolCallCard(summary)
            ))
        }
        if response.budgetExhausted {
            appendMessage(ChatMessage(
                id: UUID().uuidString,
                timestamp: clock(),
                body: .systemNote(text: "I went around in circles. Saved what I had.")
            ))
        }
    }

    private func appendMessage(_ m: ChatMessage) {
        messages.append(m)
    }

    private func removeMessage(id: String) {
        messages.removeAll(where: { $0.id == id })
    }

    /// Try to fish an event_id out of a tool-result JSON. Many Pod C tools
    /// return `{"event_id":"..."}` on success; the audit-log queries in
    /// Settings can find the same row by that id. Failure → nil (the card
    /// still renders, just without an inline Undo button).
    private func extractEventID(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let s = obj["event_id"] as? String, !s.isEmpty { return s }
        return nil
    }

    /// Cycle the input-bar placeholder once per cold launch from the set in
    /// Designer §1.5.
    private static func pickPlaceholder() -> String {
        let pool = [
            "What's going on?",
            "How's it going?",
            "Tell me anything.",
            "Log something, ask something.",
        ]
        return pool.randomElement() ?? pool[0]
    }
}

