//
//  ChatInputBar.swift
//  Steward — Track E
//
//  Per Designer §1.5–1.6. Text field grows to multi-line up to ~6 lines;
//  right-edge button toggles between send (when field has content) and mic
//  (when empty). Mic is hold-to-talk; when `VoiceCapture` is unavailable
//  we still render the button so the affordance is discoverable, but tap shows
//  a tooltip — we don't pretend it works.
//

import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    let placeholder: String
    let isSending: Bool
    let voiceAvailability: VoiceAvailability
    var onSend: () -> Void
    var onMicPressDown: () -> Void
    var onMicReleased: () -> Void
    var onMicCancelled: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var showVoiceUnavailableTip: Bool = false
    @State private var isRecording: Bool = false

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sendVisible: Bool { !trimmedText.isEmpty }

    private var displayPlaceholder: String {
        isSending ? "Steward is working…" : placeholder
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(displayPlaceholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textInputAutocapitalization(.sentences)
                .disableAutocorrection(false)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .disabled(isSending)
                .focused($fieldFocused)
                .onSubmit { if sendVisible { onSend() } }
                .accessibilityIdentifier("chat.input.field")

            trailingButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if sendVisible {
            Button {
                onSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(isSending ? Color.secondary : Color.accentColor)
            }
            .disabled(isSending)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("chat.input.send")
        } else {
            micButton
        }
    }

    @ViewBuilder
    private var micButton: some View {
        let active = (voiceAvailability == .ready) && !isSending
        let icon = isRecording ? "mic.circle.fill" : "mic.fill"
        let color: Color = isRecording ? .red : (active ? .accentColor : .secondary)
        Image(systemName: icon)
            .font(.system(size: 26))
            .foregroundStyle(color)
            .padding(8)
            .contentShape(Rectangle())
            .accessibilityLabel(active ? "Hold to talk" : "Voice unavailable")
            .accessibilityIdentifier("chat.input.mic")
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard active else { return }
                        if !isRecording {
                            isRecording = true
                            onMicPressDown()
                        }
                    }
                    .onEnded { value in
                        guard active else { return }
                        if isRecording {
                            isRecording = false
                            // Treat large drag-off as a cancel; release in-place as commit.
                            if abs(value.translation.height) > 40 || abs(value.translation.width) > 40 {
                                onMicCancelled()
                            } else {
                                onMicReleased()
                            }
                        }
                    }
            )
            .onTapGesture {
                if !active {
                    showVoiceUnavailableTip = true
                }
            }
            .popover(isPresented: $showVoiceUnavailableTip, arrowEdge: .top) {
                Text(tipCopy)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .presentationCompactAdaptation(.popover)
            }
    }

    private var tipCopy: String {
        switch voiceAvailability {
        case .ready: return "Hold to talk."
        case .notLoaded: return "Voice isn't ready right now. You can still type."
        case .permissionDenied: return "Mic access is off. You can still type."
        case .disabledInSettings: return "Voice is off in Settings. You can still type."
        }
    }
}
