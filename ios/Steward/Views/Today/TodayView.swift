//
//  TodayView.swift
//  Steward
//
//  Recent activity across the workbook — newest rows from any active
//  sheet, sorted by time. Drop-in replacement for the v1 morning-brief
//  + per-domain instrument cards UI; the workbook is now the substrate
//  the agent maintains, so Today reflects that directly.
//

import SwiftUI

struct TodayView: View {
    @StateObject private var viewModel = TodayViewModel()
    /// Invoked when the empty state's "Open Chat" affordance is tapped.
    /// With the sparkle chat overlay this presents the chat sheet rather
    /// than switching tabs.
    var onOpenChat: () -> Void = {}

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Today")
                .navigationBarTitleDisplayMode(.large)
                .refreshable { await viewModel.load() }
                .background(Color(.systemGroupedBackground))
                .task { await viewModel.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("Couldn't load Today.")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Try again") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where viewModel.workbookIsEmpty:
            TodayEmptyState(onOpenChat: onOpenChat)
        case .loaded where viewModel.rows.isEmpty:
            EmptyRowsView()
        case .loaded:
            activityList
        }
    }

    private var activityList: some View {
        List {
            Section {
                ForEach(viewModel.rows) { row in
                    NavigationLink(value: row.sheetID) {
                        ActivityRowView(row: row)
                    }
                }
            } header: {
                Text("Recent activity")
            } footer: {
                Text("Tap a row to open the sheet it belongs to.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: SheetID.self) { sheetID in
            SheetDetailView(sheetID: sheetID)
        }
    }
}

// MARK: - Row

private struct ActivityRowView: View {
    let row: TodayViewModel.ActivityRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.sheetName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Self.relativeFormatter.localizedString(
                    for: row.createdAt, relativeTo: Date()
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !row.cells.isEmpty {
                Text(cellSummary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var cellSummary: String {
        row.cells
            .filter { !$0.displayValue.isEmpty }
            .map { "\($0.columnName) · \($0.displayValue)" }
            .joined(separator: " · ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - "Sheets exist but no rows yet"

private struct EmptyRowsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing logged yet today")
                .font(.headline)
            Text("Open the sparkle chat and log a row — it'll show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
