//
//  TodayViewModel.swift
//  Steward — Track E
//
//  Pulls together everything Today renders: the most recent morning brief,
//  every active instrument grouped by domain, commitments due in the next
//  24h, and upcoming notifications. All reads are async; the view shows a
//  shimmer placeholder while loading.
//

import Foundation
import GRDB
import SwiftUI

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var domains: [DomainRecord] = []
    @Published private(set) var instrumentsByDomain: [String: [InstrumentDisplayItem]] = [:]
    @Published private(set) var commitments: [CommitmentItem] = []
    @Published private(set) var notifications: [NotificationItem] = []
    @Published private(set) var brief: BriefState = .loading
    @Published private(set) var loadError: String?

    enum BriefState: Equatable {
        case loading
        case ready(headline: String, body: String, createdAt: Date)
        case missing
        case failed(reason: String)
    }

    struct InstrumentDisplayItem: Identifiable, Equatable {
        let id: String           // instrument_id
        let name: String
        let domain: String
        let kindID: String
        let display: InstrumentDisplay
    }

    struct CommitmentItem: Identifiable, Equatable {
        let id: String
        let title: String
        let dueAt: Date?
        let domain: String?
    }

    struct NotificationItem: Identifiable, Equatable {
        let id: String
        let title: String
        let body: String
        let firesAt: Date
    }

    private let provider: DatabaseProvider
    private let domainStore: DomainStore
    private let clock: @Sendable () -> Date

    init(
        provider: DatabaseProvider = .shared,
        domainStore: DomainStore = .shared,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.domainStore = domainStore
        self.clock = clock
    }

    // MARK: - Loading

    func reload() async {
        isLoading = true
        loadError = nil
        do {
            let providerLocal = self.provider
            let now = clock()

            // 1. Domains
            let activeDomains = (try? await domainStore.listActive()) ?? []
            self.domains = activeDomains

            // 2. Instruments
            let instruments = try await loadInstruments(provider: providerLocal, now: now)
            var grouped: [String: [InstrumentDisplayItem]] = [:]
            for inst in instruments {
                grouped[inst.domain, default: []].append(inst)
            }
            self.instrumentsByDomain = grouped

            // 3. Commitments due in next 24h
            self.commitments = try await loadCommitments(provider: providerLocal, now: now)

            // 4. Upcoming notifications (next 24h)
            self.notifications = await loadUpcoming(now: now)

            // 5. Morning brief: load most recent; if >6h old, regen.
            await loadBrief(provider: providerLocal, now: now, allowRegen: !activeDomains.isEmpty)
        } catch {
            loadError = "Couldn't read your state: \(error)"
        }
        isLoading = false
    }

    func refreshBrief() async {
        await loadBrief(provider: provider, now: clock(), allowRegen: true, force: true)
    }

    /// Designer §2.5 — user dismissed an upcoming notification.
    func cancelNotification(notificationID: String) async {
        await NotificationScheduler.shared.cancel(
            id: NotificationID(rawValue: notificationID)
        )
        notifications.removeAll(where: { $0.id == notificationID })
    }

    // MARK: - Implementation details

    private func loadInstruments(
        provider: DatabaseProvider, now: Date
    ) async throws -> [InstrumentDisplayItem] {
        let db = try await provider.database()
        let rows = try await db.read { dbase -> [Row] in
            try Row.fetchAll(
                dbase,
                sql: """
                    SELECT instrument_id, domain, kind, name, state_json, definition_json,
                           last_updated_at
                    FROM instruments
                    WHERE archived_at IS NULL
                    ORDER BY domain ASC, created_at ASC
                """
            )
        }
        return rows.map { row in
            let updated = Date(
                timeIntervalSince1970: Double(row["last_updated_at"] as Int64) / 1000
            )
            let display = InstrumentDisplayProjector.project(
                kindID: row["kind"],
                stateJSON: row["state_json"],
                definitionJSON: row["definition_json"],
                lastUpdatedAt: updated,
                now: now
            )
            return InstrumentDisplayItem(
                id: row["instrument_id"],
                name: row["name"],
                domain: row["domain"],
                kindID: row["kind"],
                display: display
            )
        }
    }

    private func loadCommitments(
        provider: DatabaseProvider, now: Date
    ) async throws -> [CommitmentItem] {
        let db = try await provider.database()
        let lowMs = Int64(now.timeIntervalSince1970 * 1000)
        let highMs = Int64(now.addingTimeInterval(24 * 3600).timeIntervalSince1970 * 1000)
        let rows = try await db.read { dbase -> [Row] in
            try Row.fetchAll(
                dbase,
                sql: """
                    SELECT commitment_id, title, due_at, domain
                    FROM commitments
                    WHERE status = 'active'
                      AND (due_at IS NULL OR (due_at >= ? AND due_at <= ?))
                    ORDER BY due_at ASC NULLS LAST
                """,
                arguments: [lowMs, highMs]
            )
        }
        return rows.map { row in
            let due: Date? = (row["due_at"] as Int64?).map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            }
            return CommitmentItem(
                id: row["commitment_id"],
                title: row["title"],
                dueAt: due,
                domain: row["domain"]
            )
        }
    }

    private func loadUpcoming(now: Date) async -> [NotificationItem] {
        let upcoming = await NotificationScheduler.shared.upcoming(domain: nil)
        let cutoff = now.addingTimeInterval(24 * 3600)
        return upcoming
            .filter { $0.firesAt >= now && $0.firesAt <= cutoff }
            .sorted(by: { $0.firesAt < $1.firesAt })
            .map { sn in
                let rendered = NotificationTemplate.render(
                    kind: sn.request.kind,
                    mode: sn.mode,
                    context: sn.request.templateContext
                )
                return NotificationItem(
                    id: sn.unRequestIdentifier,
                    title: rendered.title,
                    body: rendered.body,
                    firesAt: sn.firesAt
                )
            }
    }

    private func loadBrief(
        provider: DatabaseProvider,
        now: Date,
        allowRegen: Bool,
        force: Bool = false
    ) async {
        do {
            let db = try await provider.database()
            let row: Row? = try await db.read { dbase in
                try Row.fetchOne(
                    dbase,
                    sql: """
                        SELECT text, created_at FROM events
                        WHERE kind = 'morning_brief'
                        ORDER BY created_at DESC
                        LIMIT 1
                    """
                )
            }
            if let row, let text = row["text"] as String? {
                let createdAt = Date(
                    timeIntervalSince1970: Double(row["created_at"] as Int64) / 1000
                )
                let staleHours = now.timeIntervalSince(createdAt) / 3600
                if !force && staleHours < 6 {
                    brief = .ready(
                        headline: briefHeadline(for: now),
                        body: text,
                        createdAt: createdAt
                    )
                    return
                }
            }
            if !allowRegen {
                // Empty-domain copy per Designer §2.2.
                brief = .ready(
                    headline: briefHeadline(for: now),
                    body: "Quiet stretch. Nothing's logged in a while. When you're ready, log something or tell me what's up — no pressure.",
                    createdAt: now
                )
                return
            }
            brief = .loading
            await generateBrief(provider: provider, now: now)
        } catch {
            brief = .failed(reason: String(describing: error))
        }
    }

    private func generateBrief(provider: DatabaseProvider, now: Date) async {
        do {
            let ready = try await AgentLoopHost.shared.ready()
            let response = try await ready.loop.run(userMessage: "Generate this morning's brief. Summarize current state, mention one or two specific instrument values, any commitments in the next 12h, and one optional small offer. Don't moralize.")
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                brief = .failed(reason: "empty brief response")
                return
            }
            // Persist into events so the next load doesn't regen.
            let db = try await provider.database()
            _ = try await db.write { dbase in
                try EventLog.append(
                    actor: EventActor.coordinator,
                    kind: "morning_brief",
                    text: text,
                    source: "today_view",
                    reasoning: "User opened Today tab; brief older than 6h.",
                    at: now,
                    in: dbase
                )
            }
            brief = .ready(headline: briefHeadline(for: now), body: text, createdAt: now)
        } catch {
            brief = .failed(reason: String(describing: error))
        }
    }

    private func briefHeadline(for date: Date) -> String {
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: date)
        if hour >= 4 && hour < 12 { return "This morning" }
        if hour >= 12 && hour < 17 { return "Today" }
        return "This evening"
    }
}
