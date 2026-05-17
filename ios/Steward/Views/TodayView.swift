//
//  TodayView.swift
//  Steward
//
//  Track A scaffold tab. Track E owns the real Today surface (morning brief,
//  instrument cards, upcoming commitments, upcoming notifications).
//

import SwiftUI

struct TodayView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "sun.max")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Today")
                    .font(.title2.weight(.semibold))
                Text("Morning brief, instruments, and upcoming commitments will live here.\nNo life teams yet — head to Chat to spawn one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Today")
        }
    }
}

#Preview {
    TodayView()
}
