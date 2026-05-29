//
//  SparkleChatButton.swift
//  Steward
//
//  The omnipresent agent surface: a floating sparkle button in the
//  bottom-right corner of every primary screen. Tap to present the
//  chat in a sheet over whatever you were doing — no tab switch, no
//  context loss.
//
//  Visual: an accent-tinted sparkle in a Material-circle, sized for
//  thumb hit (~56pt). Padded above the tab bar so it doesn't get
//  shadowed by the system tab indicator on iPhone.
//

import SwiftUI

struct SparkleChatButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open chat with Outkeep")
        .accessibilityIdentifier("root.sparkle.button")
    }
}

#Preview {
    ZStack {
        Color(.systemGroupedBackground).ignoresSafeArea()
        SparkleChatButton(action: {})
    }
}
