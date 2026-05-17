//
//  PermissionPromptBubble.swift
//  Steward
//
//  Inline permission-grant card per implementation-addendum §1.9. Rendered
//  when a tool throws `PermissionRequiredSignal` (EventKit) or
//  `HealthPermissionRequiredSignal` (HealthKit) mid-turn. The bubble offers
//  Allow / Not now; Allow drives the OS sheet via the appropriate gateway's
//  `requestAccess(for:)`; on grant ChatViewModel auto-retries the pending
//  tool call exactly once.
//
//  Copy comes from `PermissionPromptModel` (UXR v2 voice: direct ask, no
//  moralization, no privacy hedge — the OS sheet already covers that).
//

import SwiftUI

struct PermissionPromptBubble: View {
    let model: PermissionPromptModel
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .imageScale(.medium)
                .foregroundStyle(.tint)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                switch model.state {
                case .awaitingTap:
                    HStack(spacing: 10) {
                        Button(action: onAllow) {
                            Text("Allow")
                                .font(.body.weight(.semibold))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 14)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: onDeny) {
                            Text("Not now")
                                .font(.body)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 2)
                case .requesting:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for your choice in the system sheet…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                case .resolved(let text):
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(12)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 12)
    }

    private var iconName: String {
        switch model.kind {
        case .eventKitCalendarFull, .eventKitCalendarWrite:
            return "calendar"
        case .eventKitRemindersFull, .eventKitRemindersWrite:
            return "checklist"
        case .healthKitReadAll:
            return "heart.text.square"
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        PermissionPromptBubble(
            model: PermissionPromptModel(
                kind: .eventKitCalendarFull,
                pendingToolID: "calendar.write",
                pendingArgsJSON: "{}",
                state: .awaitingTap
            ),
            onAllow: {},
            onDeny: {}
        )
        PermissionPromptBubble(
            model: PermissionPromptModel(
                kind: .healthKitReadAll,
                pendingToolID: "health.read_quantity",
                pendingArgsJSON: "{}",
                state: .requesting
            ),
            onAllow: {},
            onDeny: {}
        )
        PermissionPromptBubble(
            model: PermissionPromptModel(
                kind: .eventKitRemindersFull,
                pendingToolID: "reminder.create",
                pendingArgsJSON: "{}",
                state: .resolved(text: "Permission denied — Outkeep will work around this.")
            ),
            onAllow: {},
            onDeny: {}
        )
    }
    .padding()
}
