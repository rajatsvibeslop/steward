//
//  UpcomingList.swift
//  Steward — Track E
//
//  Per Designer §2.5. Renders both commitments due in the next 24h AND
//  notifications scheduled in the next 24h as a single time-ordered list.
//  Notifications have a trailing dismiss button → confirmation → cancel.
//

import SwiftUI

struct UpcomingList: View {
    let commitments: [TodayViewModel.CommitmentItem]
    let notifications: [TodayViewModel.NotificationItem]
    var onCancelNotification: (String) -> Void

    @State private var pendingCancelID: String?

    private var rows: [Row] {
        let commitmentRows: [Row] = commitments.map { c in
            .commitment(c)
        }
        let notificationRows: [Row] = notifications.map { n in
            .notification(n)
        }
        return (commitmentRows + notificationRows)
            .sorted(by: { $0.sortTime < $1.sortTime })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            if rows.isEmpty {
                Text("Nothing on deck.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows, id: \.id) { row in
                        switch row {
                        case .commitment(let c):
                            commitmentRow(c)
                        case .notification(let n):
                            notificationRow(n)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Cancel this nudge?",
            isPresented: Binding(
                get: { pendingCancelID != nil },
                set: { if !$0 { pendingCancelID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Cancel nudge", role: .destructive) {
                if let id = pendingCancelID { onCancelNotification(id) }
                pendingCancelID = nil
            }
            Button("Keep", role: .cancel) { pendingCancelID = nil }
        }
    }

    @ViewBuilder
    private func commitmentRow(_ c: TodayViewModel.CommitmentItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeLabel(c.dueAt))
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 80, alignment: .leading)
            Text(c.title)
                .font(.body)
            Spacer()
            TypePill(label: "commitment")
        }
    }

    @ViewBuilder
    private func notificationRow(_ n: TodayViewModel.NotificationItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeLabel(n.firesAt))
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 80, alignment: .leading)
            Text(n.title)
                .font(.body)
            Spacer()
            TypePill(label: "notification")
            Button(action: { pendingCancelID = n.id }) {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .accessibilityLabel("Cancel notification")
            .accessibilityIdentifier("today.upcoming.cancel.\(n.id)")
        }
    }

    private func timeLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        return formatter.string(from: date)
    }
}

private struct TypePill: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

private extension UpcomingList {
    enum Row {
        case commitment(TodayViewModel.CommitmentItem)
        case notification(TodayViewModel.NotificationItem)

        var id: String {
            switch self {
            case .commitment(let c): return "c:\(c.id)"
            case .notification(let n): return "n:\(n.id)"
            }
        }

        var sortTime: Date {
            switch self {
            case .commitment(let c): return c.dueAt ?? Date.distantFuture
            case .notification(let n): return n.firesAt
            }
        }
    }
}
