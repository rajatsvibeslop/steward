//
//  ChatView.swift
//  Steward
//
//  Track A scaffold tab. Track E owns the real chat surface (input bar,
//  voice button, transcript, tool-call cards, hand-off indicator).
//

import SwiftUI

struct ChatView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Chat")
                    .font(.title2.weight(.semibold))
                Text("The coordinator conversation lives here.\nTrack E will land the real chat UI on top of this scaffold.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Chat")
        }
    }
}

#Preview {
    ChatView()
}
