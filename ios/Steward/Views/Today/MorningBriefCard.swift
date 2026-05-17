//
//  MorningBriefCard.swift
//  Steward — Track E
//
//  Top card on the Today tab. Renders the most recent morning brief (or its
//  empty-domain variant) per Designer §2.2.
//

import SwiftUI

struct MorningBriefCard: View {
    let state: TodayViewModel.BriefState
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(headline)
                    .font(.headline)
                Spacer()
                Button(action: onRefresh) {
                    HStack(spacing: 4) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                            Text("Refreshing…")
                                .font(.footnote)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.footnote)
                            Text("Refresh")
                                .font(.footnote)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .accessibilityIdentifier("today.brief.refresh")
            }
            bodyView
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var headline: String {
        switch state {
        case .ready(let headline, _, _): return headline
        case .loading, .missing, .failed: return "This morning"
        }
    }

    private var isRefreshing: Bool {
        if case .loading = state { return true }
        return false
    }

    @ViewBuilder
    private var bodyView: some View {
        switch state {
        case .loading:
            VStack(alignment: .leading, spacing: 6) {
                ShimmerLine(width: 220)
                ShimmerLine(width: 180)
                ShimmerLine(width: 200)
            }
        case .ready(_, let body, _):
            Text(body)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .missing:
            Text("Nothing yet — open Chat to log something.")
                .font(.body)
                .foregroundStyle(.secondary)
        case .failed:
            Text("Couldn't generate a brief just now. State below is fresh.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ShimmerLine: View {
    let width: CGFloat
    @State private var pulse: Bool = false

    var body: some View {
        Rectangle()
            .fill(Color(.tertiarySystemFill))
            .frame(width: width, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(pulse ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
