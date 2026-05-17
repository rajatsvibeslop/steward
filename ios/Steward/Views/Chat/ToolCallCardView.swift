//
//  ToolCallCardView.swift
//  Steward — Track E
//
//  Inline tool-call card per Designer §1.3. Collapsed by default; tap the row
//  to expand and reveal "What" / "Why" / "Result" + the Undo button (if the
//  call is reversible and we have the audit event_id to undo against).
//

import SwiftUI

struct ToolCallCardView: View {
    let summary: ToolCallSummary
    /// Tap-to-undo handler injected by ChatView so the card doesn't have to
    /// reach into actor surfaces directly. Returns the user-visible result
    /// string ("Undone." / "Couldn't undo: …") so the card can render it
    /// inline once.
    var onUndo: ((_ eventID: String) async -> String)? = nil

    @State private var expanded: Bool = false
    @State private var undoStatus: String? = nil
    @State private var undoInFlight: Bool = false
    @State private var confirmingUndo: Bool = false

    private var accentColor: Color {
        guard let key = summary.domainKey else { return .accentColor }
        return DomainColor.for(domain: key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(summary.actorLabel) · \(summary.verb) \(summary.object)")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    section(label: "What") {
                        Text("\(summary.toolID)(\(summary.argsSummary))")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let why = summary.reasoning, !why.isEmpty {
                        section(label: "Why") {
                            Text(why)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    section(label: "Result") {
                        Text(summary.resultSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if summary.isReversible, let eventID = summary.eventID, onUndo != nil {
                        HStack(spacing: 8) {
                            Button(role: .destructive) {
                                confirmingUndo = true
                            } label: {
                                Text(undoInFlight ? "Undoing…" : "Undo")
                                    .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .disabled(undoInFlight || undoStatus != nil)
                            .confirmationDialog(
                                "Undo this? Steward will roll it back.",
                                isPresented: $confirmingUndo,
                                titleVisibility: .visible
                            ) {
                                Button("Undo", role: .destructive) {
                                    Task { await runUndo(eventID: eventID) }
                                }
                                Button("Cancel", role: .cancel) {}
                            }
                            if let status = undoStatus {
                                Text(status)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            Color(.tertiarySystemBackground),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor.opacity(summary.domainKey == nil ? 0 : 1))
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func section<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func runUndo(eventID: String) async {
        guard let onUndo else { return }
        undoInFlight = true
        let result = await onUndo(eventID)
        undoStatus = result
        undoInFlight = false
    }
}
