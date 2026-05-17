//
//  TodayEmptyState.swift
//  Steward — Track E
//
//  Per Designer §2.6. Forward-looking, calm; "Open Chat" button switches
//  tabs but does NOT auto-send a message. Copy is verbatim per the spec.
//

import SwiftUI

struct TodayEmptyState: View {
    var onOpenChat: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sun.horizon")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Nothing here yet — and that's the right starting point.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Text("Head over to Chat. Tell Steward something to catch, or say \"walk me through it.\" That's where the first team gets built.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button(action: onOpenChat) {
                Text("Open Chat")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("today.empty.open_chat")
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}
