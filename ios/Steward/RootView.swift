//
//  RootView.swift
//  Steward
//
//  Track A scaffold: empty TabView holding three scaffold tabs.
//  Track E owns the real UI; this exists so the app launches and is navigable.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var bootstrap: AppBootstrap

    var body: some View {
        TabView {
            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "sun.max")
                }
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .overlay(alignment: .top) {
            BootstrapBanner(phase: bootstrap.phase)
        }
    }
}

private struct BootstrapBanner: View {
    let phase: AppBootstrap.Phase

    var body: some View {
        switch phase {
        case .idle, .ready:
            EmptyView()
        case .opening:
            HStack(spacing: 8) {
                ProgressView()
                Text("Opening Steward database…")
                    .font(.footnote)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
        case .failed(let message):
            Text("Database failed to open: \(message)")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.85), in: Capsule())
                .padding(.top, 8)
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppBootstrap())
}
