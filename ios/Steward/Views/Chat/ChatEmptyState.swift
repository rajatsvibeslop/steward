//
//  ChatEmptyState.swift
//  Steward — Track E
//
//  First-launch greeting from `CoordinatorEmptyStateCopy.greeting(forLocalHour:)`
//  (the LLM does NOT emit this — see UXR v2 §1.1). Two chips ride below the
//  input bar; "Walk me through it" fills the field with a literal string,
//  "Catch something" focuses the field and changes the placeholder (handled
//  by the parent through `onCatchSomething`).
//

import SwiftUI

struct ChatEmptyState: View {
    let greeting: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(greeting)
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

struct ChatEmptyStateChips: View {
    var onCatchSomething: () -> Void
    var onWalkMeThroughIt: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            chip(label: "Catch something", action: onCatchSomething)
                .accessibilityIdentifier("chat.empty.chip.catch")
            chip(label: "Walk me through it", action: onWalkMeThroughIt)
                .accessibilityIdentifier("chat.empty.chip.walk")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func chip(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Color(.tertiarySystemFill),
                    in: Capsule()
                )
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}
