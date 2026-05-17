//
//  SettingsView.swift
//  Steward
//
//  Track A scaffold tab. Track E owns the real Settings surface (quiet hours,
//  mercy/pause toggles, domain list, agent action audit log with undo).
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Text("Quiet hours, notification caps, mercy mode, domains, and the audit log will live here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
