//
//  RootTabView.swift
//  Steward — Track E
//
//  Replaces Track A's RootView. Three tabs in fixed order — Chat, Today,
//  Settings — per Designer §0 ("Default launch tab: Chat"). The selection
//  binding is exposed so the Today empty-state and "+ Add a team via chat"
//  Settings row can switch tabs programmatically.
//

import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var bootstrap: AppBootstrap

    enum Tab: Hashable { case chat, today, settings }

    @State private var selectedTab: Tab = .chat

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(Tab.chat)

            TodayView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Today", systemImage: "sun.horizon")
                }
                .tag(Tab.today)

            SettingsView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .tag(Tab.settings)
        }
        .tint(.accentColor)
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
    RootTabView()
        .environmentObject(AppBootstrap())
}
