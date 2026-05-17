//
//  ChatView.swift
//  Steward — Track E
//
//  Replaces Track A's scaffold. Owns the empty-state vs. transcript switch,
//  drives the input bar, and renders one of the typed `ChatMessage` cases
//  per row.
//

import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var draft: String = ""
    @State private var catchModePlaceholder: String? = nil
    @State private var voiceAvailability: VoiceAvailability = .notLoaded

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                if viewModel.shouldShowEmptyState {
                    ChatEmptyStateChips(
                        onCatchSomething: {
                            catchModePlaceholder = "What should I catch? (sleep, weight, a spend, a thing on your mind…)"
                        },
                        onWalkMeThroughIt: {
                            draft = viewModel.walkMeThroughItText()
                        }
                    )
                }
                ChatInputBar(
                    text: $draft,
                    placeholder: catchModePlaceholder ?? viewModel.placeholderText,
                    isSending: viewModel.isSending,
                    voiceAvailability: voiceAvailability,
                    onSend: sendDraft,
                    onMicPressDown: { Task { await VoiceCaptureRegistry.current.beginRecording() } },
                    onMicReleased: handleMicReleased,
                    onMicCancelled: { Task { await VoiceCaptureRegistry.current.cancelRecording() } }
                )
            }
            .background(Color(.systemBackground))
            .navigationTitle("Outkeep")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await viewModel.loadInitialState()
                await refreshVoiceAvailability()
                // Cold-launch case: a tap that delivered before SwiftUI
                // subscribed to .stewardNotificationTapped lives in the
                // router's buffer. Drain it now so the very first ChatView
                // appearance honors the routing.
                if let buffered = NotificationActionRouter.shared.takeLastTapEvent() {
                    viewModel.acceptNotificationTap(buffered)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .voiceCaptureReadinessChanged
            )) { _ in
                // Track F bootstrap posts this once WhisperKit eager init
                // completes (success or fail). Re-read availability so the
                // mic flips from disabled-with-tooltip to active when ready.
                Task { await refreshVoiceAvailability() }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .stewardNotificationTapped
            )) { note in
                // Live case: app already running, user tapped a banner.
                // Pull the typed event off the post payload directly.
                // Note: we deliberately do NOT call
                // `NotificationActionRouter.shared.takeLastTapEvent()`
                // here — every live tap also updates the buffer, and
                // draining it would race with the .task drain on the
                // next ChatView appearance (and break unit tests that
                // assert against `lastTapEvent` while the host app
                // happens to have ChatView mounted).
                if let event = note.userInfo?[
                    NotificationActionRouter.tapEventUserInfoKey
                ] as? NotificationActionRouter.TapEvent {
                    viewModel.acceptNotificationTap(event)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.shouldShowEmptyState {
            ChatEmptyState(greeting: greetingForNow())
        } else {
            transcript
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.messages) { message in
                        rowView(for: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                guard let last = viewModel.messages.last else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(for message: ChatMessage) -> some View {
        switch message.body {
        case .user(let text):
            UserBubble(text: text)
        case .coordinator(let text, let isStub):
            CoordinatorBubble(text: text, showsStubChip: isStub)
        case .domain(let key, let name, let text, let isStub):
            DomainBubble(domainKey: key, displayName: name, text: text, showsStubChip: isStub)
        case .toolCallCard(let summary):
            ToolCallCardView(summary: summary, onUndo: { eventID in
                await undoEvent(eventID: eventID)
            })
        case .handoffIndicator(let key, let name):
            HandoffIndicator(domainKey: key, displayName: name)
        case .thinkingCoordinator:
            ThinkingBubble(label: "Outkeep", domainKey: nil)
        case .thinkingDomain(let key, let name):
            ThinkingBubble(label: "\(name) team is thinking", domainKey: key)
        case .systemNote(let text):
            SystemNoteRow(text: text)
        case .stillWorkingNote:
            SystemNoteRow(text: "Still working. Foundation Models can be slow on first cold start.")
        case .permissionPrompt(let model):
            PermissionPromptBubble(
                model: model,
                onAllow: {
                    Task { await viewModel.grantPermission(forMessageID: message.id) }
                },
                onDeny: {
                    Task { await viewModel.denyPermission(forMessageID: message.id) }
                }
            )
        }
    }

    // MARK: - Actions

    /// Read availability from the registry, then apply the Settings override
    /// (`voice_capture_enabled = false` forces `.disabledInSettings`
    /// regardless of WhisperKit readiness, so the tooltip explains the user
    /// can re-enable it).
    private func refreshVoiceAvailability() async {
        var availability = await VoiceCaptureRegistry.current.availability
        if let settings = try? await SettingsStore.shared.load(),
           !settings.voiceCaptureEnabled {
            availability = .disabledInSettings
        }
        voiceAvailability = availability
    }

    private func sendDraft() {
        let payload = draft
        draft = ""
        catchModePlaceholder = nil
        Task { await viewModel.send(payload) }
    }

    private func handleMicReleased() {
        Task {
            do {
                if let transcript = try await VoiceCaptureRegistry.current.endRecordingAndTranscribe() {
                    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        draft = draft.isEmpty ? trimmed : draft + " " + trimmed
                    }
                }
            } catch {
                // Transcription failed — surface inline; the user can still type.
                draft = draft  // no-op; surface via tooltip next mic tap
            }
        }
    }

    private func undoEvent(eventID: String) async -> String {
        do {
            let outcome = try await UndoExecutor.shared.undo(
                eventID: EventID(rawValue: eventID),
                undoneBy: .user,
                reasoning: "User tapped Undo on a tool-call card."
            )
            switch outcome {
            case .undone: return "Undone."
            case .alreadyUndone: return "Already undone."
            case .notFound: return "Nothing to undo."
            case .blockedByDependents: return "Can't undo — undo dependents first."
            }
        } catch {
            return "Couldn't undo: \(error)"
        }
    }

    private func greetingForNow() -> String {
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: Date())
        return CoordinatorEmptyStateCopy.greeting(forLocalHour: hour)
    }
}

#Preview {
    ChatView()
        .environmentObject(AppBootstrap())
}
