//
//  RootTabView.swift
//  Steward
//
//  The app's root. Per the rework direction, the chat is no longer a
//  tab — it's an omnipresent sparkle button in the corner that
//  presents the agent in a sheet over whatever you were doing. The
//  tabs that remain are the surfaces you go *to* (Today / Workbook /
//  Settings); the agent comes *with* you.
//
//  Notification taps open the chat sheet automatically; on cold launch
//  ChatView drains the buffered tap from NotificationActionRouter so
//  the routing still works even before the sheet had a chance to
//  subscribe.
//

import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var bootstrap: AppBootstrap

    enum Tab: Hashable { case today, workbook, settings }

    @State private var selectedTab: Tab = .today
    @State private var isChatPresented: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            tabContent
                .overlay(alignment: .top) {
                    BootstrapBanner(phase: bootstrap.phase)
                }
            // Sparkle button is positioned above the tab bar — generous
            // bottom inset so it clears both the safe area and the tab
            // indicator on devices without a home button.
            SparkleChatButton(action: { isChatPresented = true })
                .padding(.trailing, 16)
                .padding(.bottom, 88)
        }
        .sheet(isPresented: $isChatPresented) {
            // ChatView's own NavigationStack provides the nav bar inside
            // the sheet; medium + large detents let the user keep the
            // surface they were on partially visible.
            ChatView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .stewardNotificationTapped
        )) { _ in
            // Any tap on a banner / lock-screen notification opens chat.
            // ChatView's task block reads the buffered TapEvent from
            // NotificationActionRouter and injects the suggested prompt.
            isChatPresented = true
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            TodayView(onOpenChat: { isChatPresented = true })
                .tabItem {
                    Label("Today", systemImage: "sun.horizon")
                }
                .tag(Tab.today)

            WorkbookView()
                .tabItem {
                    Label("Workbook", systemImage: "rectangle.split.3x3")
                }
                .tag(Tab.workbook)

            SettingsView(onOpenChat: { isChatPresented = true })
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .tag(Tab.settings)
        }
        .tint(.accentColor)
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
                Text("Opening Outkeep database…")
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
