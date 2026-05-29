//
//  TodayEmptyState.swift
//  Steward
//
//  Shown on Today when the workbook is brand-new — no sheets at all.
//  Once the agent creates a sheet (via sheet.create), this gives way
//  to the rows list.
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
            Text("Tap the sparkle and tell Outkeep something to track. The first sheet shows up here as soon as it's built.")
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
