//
//  TodayView.swift
//  Steward — Track E
//
//  Replaces Track A's scaffold. Brief card → instrument sections (per domain)
//  → upcoming. Pull-to-refresh re-runs brief generation and re-reads state.
//

import SwiftUI

struct TodayView: View {
    @StateObject private var viewModel = TodayViewModel()
    @Binding var selectedTab: RootTabView.Tab

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.domains.isEmpty {
                    ProgressView("Reading your state…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.domains.isEmpty {
                    TodayEmptyState {
                        selectedTab = .chat
                    }
                } else {
                    scrollContent
                }
            }
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { Task { await viewModel.refreshBrief() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Regenerate morning brief")
                }
            }
            .refreshable { await viewModel.reload() }
            .background(Color(.systemGroupedBackground))
            .task { await viewModel.reload() }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                MorningBriefCard(state: viewModel.brief) {
                    Task { await viewModel.refreshBrief() }
                }
                .padding(.horizontal, 16)

                ForEach(viewModel.domains) { domain in
                    domainSection(domain: domain)
                        .padding(.horizontal, 16)
                }

                UpcomingList(
                    commitments: viewModel.commitments,
                    notifications: viewModel.notifications,
                    onCancelNotification: { id in
                        Task { await viewModel.cancelNotification(notificationID: id) }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func domainSection(domain: DomainRecord) -> some View {
        let items = viewModel.instrumentsByDomain[domain.domain] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(domain.displayName) team")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            Rectangle()
                .fill(DomainColor.for(domain: domain.domain))
                .frame(width: 40, height: 2)
            if items.isEmpty {
                Text("No instruments yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ],
                    spacing: 12
                ) {
                    ForEach(items) { InstrumentCard(item: $0) }
                }
            }
        }
    }
}
