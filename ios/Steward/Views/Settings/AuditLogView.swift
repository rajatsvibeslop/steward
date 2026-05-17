//
//  AuditLogView.swift
//  Steward — Track E
//
//  Designer §3.5. Reads externally-mutating agent events from the `events`
//  table, decodes `TurnAction` from `payload_json`, and offers per-row undo
//  via `UndoExecutor.shared`. Grouped by day (today / yesterday / earlier).
//

import Foundation
import GRDB
import SwiftUI

@MainActor
final class AuditLogViewModel: ObservableObject {
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loadError: String?
    @Published var pendingUndo: Entry?

    struct Entry: Identifiable, Equatable {
        let id: String                    // event_id
        let createdAt: Date
        let actorLabel: String
        let domainKey: String?
        let kind: String
        let reasoning: String?
        let summary: String
        let isReversible: Bool
        let alreadyUndone: Bool
    }

    /// Subset of `events.kind` we surface in the activity feed (Designer §3.5).
    /// Membership is gated on whether the tool actually writes a TurnAction
    /// audit row — Pod C tools without a matching `InverseAction` case don't
    /// emit one, so listing them here would render rows the user can't undo
    /// (qa-1's bug: "Nothing to undo" alerts). The 5 Pod C tools below are
    /// the ones whose inverses live in `InverseAction` and have real
    /// `UndoExecutor` handlers.
    static let externallyMutating: Set<String> = [
        ToolID.calendarWrite.rawValue,
        ToolID.calendarModify.rawValue,
        ToolID.calendarDelete.rawValue,
        ToolID.reminderCreate.rawValue,
        ToolID.reminderComplete.rawValue,
        ToolID.notificationSchedule.rawValue,
        ToolID.notificationScheduleRecurring.rawValue,
        ToolID.notificationCancel.rawValue,
        ToolID.instrumentApplyEvent.rawValue,
        ToolID.domainCreate.rawValue,
        ToolID.domainArchive.rawValue,
        ToolID.memorySave.rawValue,
        ToolID.memoryForget.rawValue,
        ToolID.mercyModeEngage.rawValue,
        ToolID.pauseEngage.rawValue,
        ToolID.quietHoursSet.rawValue,
    ]

    private let provider: DatabaseProvider

    init(provider: DatabaseProvider = .shared) {
        self.provider = provider
    }

    func load(limit: Int = 50) async {
        do {
            let db = try await provider.database()
            let rows = try await db.read { dbase -> [Row] in
                let placeholders = Array(repeating: "?", count: Self.externallyMutating.count).joined(separator: ",")
                let kinds = Array(Self.externallyMutating)
                let sql = """
                    SELECT event_id, created_at, actor, kind, domain, text, payload_json, reasoning
                    FROM events
                    WHERE (actor LIKE 'agent:%' OR actor = 'coordinator' OR actor = 'user')
                      AND kind IN (\(placeholders))
                    ORDER BY created_at DESC
                    LIMIT \(limit)
                """
                return try Row.fetchAll(dbase, sql: sql, arguments: StatementArguments(kinds))
            }
            // Collect undo events to mark prior entries as undone.
            let undoneIDs = try await loadUndoneIDs(provider: provider, db: db)
            self.entries = rows.map { row in
                let eventID: String = row["event_id"]
                let actorRaw: String = row["actor"]
                let kind: String = row["kind"]
                let createdMs: Int64 = row["created_at"]
                let createdAt = Date(timeIntervalSince1970: Double(createdMs) / 1000)
                let reasoning: String? = row["reasoning"]
                let domain: String? = row["domain"]
                let payloadJSON: String? = row["payload_json"]
                let summary = makeSummary(
                    text: row["text"], kind: kind, domain: domain, payloadJSON: payloadJSON
                )
                return Entry(
                    id: eventID,
                    createdAt: createdAt,
                    actorLabel: prettyActor(actorRaw),
                    domainKey: domain,
                    kind: kind,
                    reasoning: reasoning,
                    summary: summary,
                    isReversible: ToolID(rawValue: kind).flatMap { reversibleSet.contains($0) } ?? false,
                    alreadyUndone: undoneIDs.contains(eventID)
                )
            }
            self.loadError = nil
        } catch {
            self.loadError = String(describing: error)
        }
    }

    func undo(entryID: String) async -> String {
        do {
            let outcome = try await UndoExecutor.shared.undo(
                eventID: EventID(rawValue: entryID),
                undoneBy: .user,
                reasoning: "User tapped Undo in Settings → Recent actions."
            )
            // Refresh markers + bail.
            await load()
            switch outcome {
            case .undone: return "Undone."
            case .alreadyUndone: return "Already undone."
            case .notFound: return "Nothing to undo."
            case .blockedByDependents: return "Can't undo — undo dependents first."
            }
        } catch {
            return "Couldn't undo: \(error)"
        }
    }

    // MARK: - Helpers

    private let reversibleSet: Set<ToolID> = [
        .calendarWrite, .calendarModify, .calendarDelete,
        .reminderCreate, .reminderComplete,
        .notificationSchedule, .notificationScheduleRecurring, .notificationCancel,
        .instrumentApplyEvent,
        .domainCreate, .domainArchive,
        .memorySave, .memoryForget,
    ]

    private func loadUndoneIDs(provider: DatabaseProvider, db: DatabaseQueue) async throws -> Set<String> {
        let rows = try await db.read { dbase -> [Row] in
            try Row.fetchAll(
                dbase,
                sql: """
                    SELECT payload_json FROM events
                    WHERE kind = 'undo'
                """
            )
        }
        var ids: Set<String> = []
        for row in rows {
            guard let json: String = row["payload_json"],
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let originalID = obj["original_event_id"] as? String
            else { continue }
            ids.insert(originalID)
        }
        return ids
    }

    private func prettyActor(_ raw: String) -> String {
        if raw == "coordinator" { return "Steward" }
        if raw.hasPrefix("agent:") {
            return String(raw.dropFirst("agent:".count)).capitalized + " team"
        }
        if raw == "user" { return "You" }
        return raw.capitalized
    }

    private func makeSummary(text: String?, kind: String, domain: String?, payloadJSON: String?) -> String {
        if let text, !text.isEmpty { return text }
        return kind.replacingOccurrences(of: "_", with: " ")
    }
}

struct AuditLogView: View {
    @StateObject private var viewModel = AuditLogViewModel()
    @State private var undoStatusByID: [String: String] = [:]

    var body: some View {
        List {
            if viewModel.entries.isEmpty {
                Section {
                    Text("Nothing here yet. Steward's actions will show up here as they happen.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(groupedSections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
            if let err = viewModel.loadError {
                Section {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Recent actions")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .confirmationDialog(
            "Undo this action? Steward will roll it back.",
            isPresented: Binding(
                get: { viewModel.pendingUndo != nil },
                set: { if !$0 { viewModel.pendingUndo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Undo", role: .destructive) {
                if let pending = viewModel.pendingUndo {
                    Task {
                        let status = await viewModel.undo(entryID: pending.id)
                        undoStatusByID[pending.id] = status
                    }
                }
                viewModel.pendingUndo = nil
            }
            Button("Cancel", role: .cancel) { viewModel.pendingUndo = nil }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: AuditLogViewModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(timeLabel(entry.createdAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.actorLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(domainColor(entry.domainKey))
            }
            Text(entry.summary)
                .font(.body)
                .strikethrough(entry.alreadyUndone, color: .secondary)
                .foregroundStyle(entry.alreadyUndone ? .secondary : .primary)
            if let why = entry.reasoning, !why.isEmpty {
                Text("Why: \(why)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if entry.alreadyUndone {
                Text("Undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if entry.isReversible {
                HStack(spacing: 8) {
                    Button("Undo", role: .destructive) {
                        viewModel.pendingUndo = entry
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.audit.undo.\(entry.id)")
                    if let status = undoStatusByID[entry.id] {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func domainColor(_ key: String?) -> Color {
        guard let key else { return .secondary }
        return DomainColor.for(domain: key)
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    // MARK: - Grouping

    private struct DaySection {
        let title: String
        let entries: [AuditLogViewModel.Entry]
    }

    private var groupedSections: [DaySection] {
        let cal = Calendar.autoupdatingCurrent
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        var todayBucket: [AuditLogViewModel.Entry] = []
        var yesterdayBucket: [AuditLogViewModel.Entry] = []
        var earlier: [AuditLogViewModel.Entry] = []
        for e in viewModel.entries {
            let day = cal.startOfDay(for: e.createdAt)
            if day == today { todayBucket.append(e) }
            else if day == yesterday { yesterdayBucket.append(e) }
            else { earlier.append(e) }
        }
        var out: [DaySection] = []
        if !todayBucket.isEmpty { out.append(.init(title: "TODAY", entries: todayBucket)) }
        if !yesterdayBucket.isEmpty { out.append(.init(title: "YESTERDAY", entries: yesterdayBucket)) }
        if !earlier.isEmpty { out.append(.init(title: "EARLIER", entries: earlier)) }
        return out
    }
}
