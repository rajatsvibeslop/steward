//
//  SettingsView.swift
//  Steward
//
//  Replaces the app entry point. Native grouped Form layout per Designer §3.1.
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @Binding var selectedTab: RootTabView.Tab

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
                    onOpenChat: { selectedTab = .chat },
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
