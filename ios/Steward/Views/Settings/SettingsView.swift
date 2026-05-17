//
//  SettingsView.swift
//  Steward — Track E
//
//  Replaces the Track A scaffold. Native grouped Form layout per Designer §3.1.
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @Binding var selectedTab: RootTabView.Tab

    var body: some View {
        NavigationStack {
            Form {
                TimingSection(settings: viewModel.settings) { mutate in
                    Task { await viewModel.update(mutate) }
                }
                ModesSection(settings: viewModel.settings) { mutate in
                    Task { await viewModel.update(mutate) }
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
                CaptureSection(settings: viewModel.settings) { mutate in
                    Task { await viewModel.update(mutate) }
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
