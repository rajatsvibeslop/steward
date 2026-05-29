//
//  SettingsView.swift
//  Steward
//
//  Replaces the app entry point. Native grouped Form layout per Designer §3.1.
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    /// Invoked when the "Add a team via chat" row is tapped. With the
    /// sparkle chat overlay this presents the chat sheet rather than
    /// switching tabs.
    var onOpenChat: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                TimingSection(settings: viewModel.settings) { field, mutate in
                    Task { await viewModel.update(audit: field, mutate) }
                }
                ModesSection(settings: viewModel.settings) { field, mutate in
                    Task { await viewModel.update(audit: field, mutate) }
                }
                LifeTeamsSection(
                    domains: viewModel.domains,
                    onOpenChat: onOpenChat,
                    onRefresh: { await viewModel.load() }
                )
                Section("ACTIVITY") {
                    NavigationLink {
                        AuditLogView()
                    } label: {
                        Text("Recent actions")
                    }
                    .accessibilityIdentifier("settings.recent_actions")
                }
                CaptureSection(settings: viewModel.settings) { field, mutate in
                    Task { await viewModel.update(audit: field, mutate) }
                }
                AboutSection(backendKind: viewModel.backendKind)
                if let err = viewModel.loadError {
                    Section {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
        }
    }
}
