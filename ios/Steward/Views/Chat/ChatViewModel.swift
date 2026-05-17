//
//  ChatViewModel.swift
//  Steward
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

import EventKit
import Foundation
import GRDB
import SwiftUI

/// Tiny abstraction over the side-effects ChatViewModel needs for the
/// inline permission-grant flow (addendum §1.9). Production wires this to
/// the real `EventKitGateway` / `HealthKitGateway` and `AgentLoopHost`;
/// tests inject a stub so the qa flow runs without touching EKEventStore /
/// HKHealthStore. Sendable + non-isolated so the default value can be
/// constructed from any actor context.
protocol PermissionFlowGateway: Sendable {
    /// Drive the OS sheet for an EventKit scope; returns the post-call
    /// status. Wired in production to `EventKitGateway.shared.requestAccess`.
    func requestEventKitAccess(scope: EKPermissionScope) async -> EKAuthorizationStatus

    /// Drive the OS sheet for a HealthKit scope; returns the post-call
    /// state. Wired in production to `HealthKitGateway.shared.requestAccess`.
    func requestHealthKitAccess(scope: HealthPermissionScope) async -> HealthAuthState

    /// Re-fire the original tool invocation. Wired in production to
    /// `AgentLoopHost.shared.retryToolCall`. The retry path does NOT run
    /// the LLM — it directly invokes the tool through the registry, so
    /// the user sees the actual result with no extra round-trip.
    func retryToolCall(toolID: String, argsJSON: String) async throws -> String
}

/// Production wiring. Lives at the top of the file so the default-init for
/// `ChatViewModel` stays in one place.
struct LivePermissionFlowGateway: PermissionFlowGateway {
    func requestEventKitAccess(scope: EKPermissionScope) async -> EKAuthorizationStatus {
        await EventKitGateway.shared.requestAccess(for: scope)
    }
    func requestHealthKitAccess(scope: HealthPermissionScope) async -> HealthAuthState {
        await HealthKitGateway.shared.requestAccess(for: scope)
    }
    func retryToolCall(toolID: String, argsJSON: String) async throws -> String {
        try await AgentLoopHost.shared.retryToolCall(toolID: toolID, argsJSON: argsJSON)
    }
}

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
    private let permissionFlow: any PermissionFlowGateway

    init(
        provider: DatabaseProvider = .shared,
        domainStore: DomainStore = .shared,
        clock: @escaping @Sendable () -> Date = { Date() },
        permissionFlow: any PermissionFlowGateway = LivePermissionFlowGateway()
    ) {
        self.provider = provider
        self.domainStore = domainStore
        self.clock = clock
        self.permissionFlow = permissionFlow
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
        } catch let signal as PermissionRequiredSignal {
            // addendum §1.9 — EventKit tool asked for a permission we
            // haven't been granted yet. Drop the thinking placeholder,
            // surface the inline grant card. Auto-retry-once happens in
            // `grantPermission(forMessageID:)` if the user taps Allow.
            removeMessage(id: thinkingID)
            handleEventKitPermissionRequired(signal: signal)
        } catch let signal as HealthPermissionRequiredSignal {
            removeMessage(id: thinkingID)
            handleHealthKitPermissionRequired(signal: signal)
        } catch {
            removeMessage(id: thinkingID)
            let errorText = "Outkeep took too long. Saved your message — tap to retry."
            appendMessage(ChatMessage(
                id: UUID().uuidString,
                timestamp: clock(),
                body: .systemNote(text: errorText)
            ))
            lastError = String(describing: error)
        }
        isSending = false
    }

    // MARK: - Permission flow (addendum §1.9)

    /// Surface an EventKit permission-grant card inline. The signal carries
    /// the original tool invocation (toolID + argsJSON) so Allow can
    /// re-fire exactly what the LLM asked for.
    ///
    /// `internal` so the unit-test target can exercise the catch-arm
    /// behavior without spinning up the live `AgentLoopHost` singleton.
    func handleEventKitPermissionRequired(signal: PermissionRequiredSignal) {
        let kind: PermissionPromptModel.Kind = {
            switch signal.scope {
            case .calendarFullAccess: return .eventKitCalendarFull
            case .calendarWriteOnly: return .eventKitCalendarWrite
            case .remindersFullAccess: return .eventKitRemindersFull
            case .remindersWriteOnly: return .eventKitRemindersWrite
            }
        }()
        let model = PermissionPromptModel(
            kind: kind,
            pendingToolID: signal.pendingToolID,
            pendingArgsJSON: signal.pendingArgsJSON,
            state: .awaitingTap
        )
        appendMessage(ChatMessage(
            id: UUID().uuidString,
            timestamp: clock(),
            body: .permissionPrompt(model)
        ))
    }

    func handleHealthKitPermissionRequired(signal: HealthPermissionRequiredSignal) {
        let kind: PermissionPromptModel.Kind = {
            switch signal.scope {
            case .readAll: return .healthKitReadAll
            }
        }()
        let model = PermissionPromptModel(
            kind: kind,
            pendingToolID: signal.pendingToolID,
            pendingArgsJSON: signal.pendingArgsJSON,
            state: .awaitingTap
        )
        appendMessage(ChatMessage(
            id: UUID().uuidString,
            timestamp: clock(),
            body: .permissionPrompt(model)
        ))
    }

    /// User tapped Allow on a permission-prompt bubble. Drives the OS
    /// sheet via the appropriate gateway; on grant, re-fires the pending
    /// tool call exactly once (addendum §1.9 — "auto-retries the original
    /// tool call once"); on deny, marks the bubble resolved with a
    /// systemNote-style follow-up explaining Steward will route around.
    func grantPermission(forMessageID id: String) async {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              case .permissionPrompt(var model) = messages[index].body else {
            return
        }
        model.state = .requesting
        replaceMessage(at: index, with: .permissionPrompt(model))

        let granted: Bool
        switch model.kind {
        case .eventKitCalendarFull:
            granted = isGranted(await permissionFlow.requestEventKitAccess(scope: .calendarFullAccess))
        case .eventKitCalendarWrite:
            granted = isGranted(await permissionFlow.requestEventKitAccess(scope: .calendarWriteOnly))
        case .eventKitRemindersFull:
            granted = isGranted(await permissionFlow.requestEventKitAccess(scope: .remindersFullAccess))
        case .eventKitRemindersWrite:
            granted = isGranted(await permissionFlow.requestEventKitAccess(scope: .remindersWriteOnly))
        case .healthKitReadAll:
            granted = isGranted(await permissionFlow.requestHealthKitAccess(scope: .readAll))
        }

        if granted {
            await retryPendingToolCall(at: id, model: model)
        } else {
            resolvePromptDenied(at: id, model: model)
        }
    }

    /// User tapped Not now. No OS sheet; bubble resolves to a deny note,
    /// and the original prompt is dropped — addendum §1.9 says we don't
    /// loop, and the LLM never sees `.permissionRequired`, so there's no
    /// model-side recovery to wait on.
    func denyPermission(forMessageID id: String) async {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              case .permissionPrompt(let model) = messages[index].body else {
            return
        }
        resolvePromptDenied(at: id, model: model)
    }

    private func retryPendingToolCall(at promptID: String, model: PermissionPromptModel) async {
        guard let toolID = model.pendingToolID,
              let argsJSON = model.pendingArgsJSON else {
            // Nothing concrete to retry (defensive — the session layer
            // always enriches the signal, but if some future tool throws
            // bare, fall back to acknowledging the grant without re-firing).
            updatePrompt(id: promptID, state: .resolved(text: "Access granted."))
            return
        }
        do {
            _ = try await permissionFlow.retryToolCall(toolID: toolID, argsJSON: argsJSON)
            updatePrompt(id: promptID, state: .resolved(text: "Access granted. Done."))
        } catch let signal as PermissionRequiredSignal {
            // Status flipped between grant + retry (race with another
            // process toggling Settings). Single-shot: don't loop.
            updatePrompt(
                id: promptID,
                state: .resolved(text: "Couldn't complete the action — \(scopeLabel(signal.scope)) access didn't stick.")
            )
        } catch let signal as HealthPermissionRequiredSignal {
            updatePrompt(
                id: promptID,
                state: .resolved(text: "Couldn't complete the action — Health access didn't stick.")
            )
            _ = signal // explicit to make non-loop intent obvious to readers
        } catch {
            updatePrompt(
                id: promptID,
                state: .resolved(text: "Couldn't complete the action: \(String(describing: error))")
            )
        }
    }

    private func resolvePromptDenied(at promptID: String, model: PermissionPromptModel) {
        updatePrompt(
            id: promptID,
            state: .resolved(text: "Not allowed — Outkeep will work around this.")
        )
    }

    private func updatePrompt(id: String, state: PermissionPromptModel.State) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              case .permissionPrompt(var model) = messages[index].body else {
            return
        }
        model.state = state
        replaceMessage(at: index, with: .permissionPrompt(model))
    }

    private func replaceMessage(at index: Int, with body: ChatMessage.Body) {
        let existing = messages[index]
        messages[index] = ChatMessage(id: existing.id, timestamp: existing.timestamp, body: body)
    }

    private func isGranted(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .fullAccess, .writeOnly, .authorized: return true
        case .notDetermined, .denied, .restricted: return false
        @unknown default: return false
        }
    }

    private func isGranted(_ state: HealthAuthState) -> Bool {
        switch state {
        case .authorized: return true
        case .notDetermined, .denied, .error: return false
        }
    }

    private func scopeLabel(_ scope: EKPermissionScope) -> String {
        switch scope {
        case .calendarFullAccess, .calendarWriteOnly: return "Calendar"
        case .remindersFullAccess, .remindersWriteOnly: return "Reminders"
        }
    }

    /// User tapped "Walk me through it" chip — fill the input with the literal
    /// string but DO NOT auto-send (§1.7).
    func walkMeThroughItText() -> String { "walk me through it" }

    // MARK: - Notification tap routing

    /// Consume a tap event delivered by `NotificationActionRouter`. We
    /// inject a coordinator-initiated bubble carrying the suggested
    /// prompt — the user can reply in the input bar to act on it, or
    /// ignore it. Malformed taps surface as a systemNote so the user
    /// knows the notification context was lost rather than silently
    /// being dropped into the chat root (hard-reject "no silent
    /// fallback that opens to chat root without ANY indication").
    func acceptNotificationTap(_ event: NotificationActionRouter.TapEvent) {
        switch event {
        case .routed(let context):
            let prompt = context.suggestedPrompt ?? "Want to log something here?"
            appendMessage(ChatMessage(
                id: UUID().uuidString,
                timestamp: clock(),
                body: .coordinator(text: prompt, isStub: false)
            ))
            // Once we've injected a coordinator-initiated bubble there
            // is conversation content; hide the greeting on next render.
            hasAnyHistory = true
        case .malformed(let reason):
            appendMessage(ChatMessage(
                id: UUID().uuidString,
                timestamp: clock(),
                body: .systemNote(text:
                    "Outkeep couldn't read that notification cleanly (\(reason))."
                )
            ))
        }
    }

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
                defaultActorLabel: "Outkeep",
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

    /// Try to fish an event_id out of a tool-result JSON. Many tool-catalog tools
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

