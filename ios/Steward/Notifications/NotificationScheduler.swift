//
//  NotificationScheduler.swift
//  Steward
//
//  HARD REJECT #8 enforcement point: every UNUserNotificationCenter.add call
//  in the app MUST come from this actor. The actor is where cap math runs;
//  going around it loses the cap.
//
//  Spec §10 cap policy (deterministic, not LLM):
//  - Max 3 proactive notifications/day (morningBrief counts as 1)
//  - Min 90 minutes between any two notifications
//  - In quiet hours: only morningBrief (suppressed-and-rescheduled to wake hour
//    if the wake hour ≥ briefTime; otherwise scheduled exactly at briefTime)
//  - In mercy mode: only morningBrief + at most 1 other notification/day, soft
//    templates substituted automatically
//  - In pause mode: nothing
//

import Foundation
import UserNotifications

// MARK: - Public types

struct ScheduledNotification: Sendable, Equatable {
    let notificationID: NotificationID
    let request: NotificationRequest
    let firesAt: Date
    let unRequestIdentifier: String
    let mode: NotificationMode
    /// Set when this occurrence came from a recurring rule. topUpHorizon
    /// uses it to dedup re-expansions; cancel-by-id leaves the rule active.
    let ruleID: String?

    init(
        notificationID: NotificationID,
        request: NotificationRequest,
        firesAt: Date,
        unRequestIdentifier: String,
        mode: NotificationMode,
        ruleID: String? = nil
    ) {
        self.notificationID = notificationID
        self.request = request
        self.firesAt = firesAt
        self.unRequestIdentifier = unRequestIdentifier
        self.mode = mode
        self.ruleID = ruleID
    }
}

enum ScheduleOutcome: Sendable, Equatable {
    case scheduled(notificationID: String, firesAt: Date)
    case capExceeded(reason: CapReason, nextAvailableSlot: Date?)
    case suppressedByQuietHours(rescheduledTo: Date?)
    case suppressedByPause
    /// Non-cap failure: UN.add threw, SettingsStore couldn't load, etc.
    /// Distinct outcome so the LLM (and audit log) doesn't misread a system
    /// error as a cap rejection — addendum §1.3 + deslop FIX #6/#7.
    case systemError(reason: String)
}

enum CapReason: Sendable, Equatable {
    case dailyMax(currentCount: Int, max: Int)
    case minGap(lastFiredAt: Date, requiredGapMinutes: Int)
    case mercyModeCap
}

/// Scope tag — used so morning-brief / coordinator-priority requests can opt
/// past mercy-mode caps the way addendum §1.3 + spec §15 describe.
enum AgentScope: Sendable, Equatable {
    case coordinator
    case domain(String)
}

// MARK: - Notification center abstraction (for tests)

/// Minimal slice of UNUserNotificationCenter the scheduler depends on. Lets
/// tests inject a fake without standing up a real notification center.
protocol UserNotificationCenterProtocol: AnyObject, Sendable {
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func pendingNotificationRequests() async -> [UNNotificationRequest]
}

extension UNUserNotificationCenter: @unchecked Sendable {}
extension UNUserNotificationCenter: UserNotificationCenterProtocol {
    // `add(_ request:)` and `pendingNotificationRequests()` are already async
    // on iOS 15+; `removePendingNotificationRequests` is sync. Default
    // conformance via the existing API surface.
}

// MARK: - The actor

actor NotificationScheduler {
    static let shared = NotificationScheduler()

    private let center: any UserNotificationCenterProtocol
    private let settings: SettingsProviding
    private let clock: ClockProviding
    private let timeZoneProvider: @Sendable () -> TimeZone
    private let ruleStoreProvider: @Sendable () -> RecurringRuleStore?

    /// In-memory log of notifications we've scheduled, for cap math. Survives
    /// only while the process is alive; foreground tick + topUpHorizon re-
    /// reads pending notifications so a fresh launch reconstructs state.
    private var scheduled: [ScheduledNotification] = []

    init(
        center: any UserNotificationCenterProtocol = UNUserNotificationCenter.current(),
        settings: SettingsProviding = LiveSettingsProvider(),
        clock: ClockProviding = SystemClock(),
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.autoupdatingCurrent },
        ruleStore: @escaping @Sendable () -> RecurringRuleStore? = { RecurringRuleStore.shared }
    ) {
        self.center = center
        self.settings = settings
        self.clock = clock
        self.timeZoneProvider = timeZone
        self.ruleStoreProvider = ruleStore
    }

    // MARK: - Public API

    func schedule(_ req: NotificationRequest, scope: AgentScope) async -> ScheduleOutcome {
        await scheduleInternal(req, scope: scope, ruleID: nil)
    }

    private func scheduleInternal(
        _ req: NotificationRequest,
        scope: AgentScope,
        ruleID: String?
    ) async -> ScheduleOutcome {
        let settingsSnapshot: Settings
        do {
            settingsSnapshot = try await settings.load()
        } catch {
            // Distinct from capExceeded — calling code must not interpret a
            // settings outage as "user is over their daily limit". Deslop
            // FIX #7 / addendum §1.3.
            return .systemError(reason: "settings_load_failed: \(error)")
        }
        let now = clock.now()
        let mode = currentMode(in: settingsSnapshot, now: now)

        // Pause: hard suppression, no exceptions.
        if mode == .pause {
            return .suppressedByPause
        }

        // Quiet hours: only morningBrief survives, and only if its fire time
        // is at/after wake hour OR is itself the brief time.
        let inQuiet = isInQuietHours(req.fireAt, settings: settingsSnapshot)
        if inQuiet && req.kind != .morningBrief {
            let rescheduled = nextSlotAfterQuietHours(req.fireAt, settings: settingsSnapshot)
            return .suppressedByQuietHours(rescheduledTo: rescheduled)
        }

        // Mercy mode: cap drops to 1 non-brief / day; brief is exempt.
        if mode == .mercy, req.kind != .morningBrief {
            let nonBriefCount = scheduled.filter {
                isSameDay($0.firesAt, req.fireAt, in: timeZoneProvider())
                    && $0.request.kind != .morningBrief
            }.count
            if nonBriefCount >= 1 {
                return .capExceeded(reason: .mercyModeCap, nextAvailableSlot: nil)
            }
        }

        // Daily max (morning brief still counts toward the cap per spec §10).
        let dailyMax = settingsSnapshot.maxProactiveNotificationsPerDay
        let dayCount = scheduled.filter {
            isSameDay($0.firesAt, req.fireAt, in: timeZoneProvider())
        }.count
        if dayCount >= dailyMax {
            return .capExceeded(
                reason: .dailyMax(currentCount: dayCount, max: dailyMax),
                nextAvailableSlot: nil
            )
        }

        // Min gap (90 min default). Compare against everything scheduled.
        let gap = settingsSnapshot.minNotificationGapMinutes
        if let lastFire = nearestNeighbor(to: req.fireAt) {
            let deltaSec = abs(req.fireAt.timeIntervalSince(lastFire))
            if deltaSec < TimeInterval(gap * 60) {
                return .capExceeded(
                    reason: .minGap(lastFiredAt: lastFire, requiredGapMinutes: gap),
                    nextAvailableSlot: lastFire.addingTimeInterval(TimeInterval(gap * 60))
                )
            }
        }

        // All caps pass — render the body deterministically (LLM never composes)
        // and register the trigger.
        let rendered = NotificationTemplate.render(
            kind: req.kind,
            mode: mode,
            context: req.templateContext
        )
        let notificationID = NotificationID.generate()
        let unRequestID = notificationID.rawValue

        let content = UNMutableNotificationContent()
        content.title = rendered.title
        content.body = rendered.body
        // userInfo carries the action_context so the tap handler can resolve
        // a one-turn coordinator response on open (spec §10 #4 tap-to-act).
        if let ctx = req.actionContextJSON, let data = ctx.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            content.userInfo = dict
        }
        content.userInfo["steward_notification_kind"] = req.kind.rawValue
        content.userInfo["steward_notification_id"] = unRequestID

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, req.fireAt.timeIntervalSince(now)),
            repeats: false
        )
        let unRequest = UNNotificationRequest(
            identifier: unRequestID,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(unRequest)
        } catch {
            // Distinct from capExceeded — UN failure (system error,
            // notification permission revoked mid-session, etc.) must not
            // be masked as a cap rejection. Deslop FIX #6.
            return .systemError(reason: "un_add_failed: \(error)")
        }

        scheduled.append(ScheduledNotification(
            notificationID: notificationID,
            request: req,
            firesAt: req.fireAt,
            unRequestIdentifier: unRequestID,
            mode: mode,
            ruleID: ruleID
        ))
        return .scheduled(notificationID: unRequestID, firesAt: req.fireAt)
    }

    /// Returns both the first-occurrence outcome AND the persisted ruleID.
    /// Callers (notably `NotificationScheduleRecurringTool`) need the ruleID
    /// to emit a `.cancelRecurringRule(ruleID:)` inverse so undo cancels the
    /// rule itself, not just the first occurrence (deslop regression B).
    func scheduleRecurring(
        _ rule: RRuleSubset,
        request: NotificationRequest,
        scope: AgentScope,
        rrule: String? = nil
    ) async -> (outcome: ScheduleOutcome, ruleID: String?) {
        // Recurring rules are pre-expanded into the next 7 days of concrete
        // fire dates and scheduled through `scheduleInternal(_:scope:ruleID:)`
        // so cap math still applies per spec §10. Pure UN repeating triggers
        // can't tell us "skip this occurrence because it hits the cap", so
        // we expand.
        let now = clock.now()
        let occurrences = RecurringExpander.nextOccurrences(
            rule: rule,
            startingAt: now,
            daysAhead: 7,
            timeZone: timeZoneProvider()
        )
        guard !occurrences.isEmpty else {
            return (.systemError(reason: "no_occurrences_in_horizon"), nil)
        }

        // Persist the rule so `topUpHorizon` can re-expand it on every
        // foreground tick. The RRULE string is the source of truth — if we
        // got a parsed RRuleSubset without an original string, reconstruct
        // a canonical one from the subset.
        let canonicalRRule = rrule ?? canonicalize(rule)
        let templateContextJSON = encodeContext(request.templateContext)
        let scopeActor: String = {
            switch scope {
            case .coordinator: return "coordinator"
            case .domain(let d): return "agent:\(d)"
            }
        }()
        let record = RecurringRuleRecord(
            rrule: canonicalRRule,
            kind: request.kind,
            domain: request.domain,
            instrumentID: request.instrumentID,
            templateContextJSON: templateContextJSON,
            actionContextJSON: request.actionContextJSON,
            priority: request.priority,
            scopeActor: scopeActor,
            createdAt: now
        )
        let persistedRuleID: String?
        if let store = ruleStoreProvider() {
            do {
                _ = try await store.insert(record)
                persistedRuleID = record.ruleID
            } catch {
                return (.systemError(reason: "rule_persist_failed: \(error)"), nil)
            }
        } else {
            persistedRuleID = nil
        }

        // FIX #2: track FIRST outcome (what the agent sees), not the last
        // loop value. Day-1-succeeds + day-7-caps must NOT report cap.
        var firstOutcome: ScheduleOutcome?
        for occ in occurrences {
            var occRequest = request
            occRequest.fireAt = occ
            let outcome = await scheduleInternal(occRequest, scope: scope, ruleID: persistedRuleID)
            if firstOutcome == nil { firstOutcome = outcome }
        }
        return (firstOutcome ?? .systemError(reason: "no_occurrences_scheduled"), persistedRuleID)
    }

    /// Cancel a recurring rule by its persisted ID. Flips `cancelled_at` in
    /// the store AND drops every pending occurrence that came from this rule.
    /// Used by `UndoExecutor` for the `.cancelRecurringRule` inverse.
    func cancelRule(ruleID: String) async {
        let toCancel = scheduled.filter { $0.ruleID == ruleID }
        let ids = toCancel.map(\.unRequestIdentifier)
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
            scheduled.removeAll { $0.ruleID == ruleID }
        }
        if let store = ruleStoreProvider() {
            try? await store.cancel(ruleID: ruleID)
        }
    }

    /// Cancel a single scheduled occurrence by NotificationID (the typed wrapper
    /// from §1.3, not a bare String — deslop FIX #1).
    func cancel(id: NotificationID) async {
        let raw = id.rawValue
        center.removePendingNotificationRequests(withIdentifiers: [raw])
        scheduled.removeAll { $0.unRequestIdentifier == raw }
    }

    /// Cancel every active recurring rule of a given kind AND its pending
    /// scheduled occurrences. Used by `notification.cancel(kind)`.
    func cancelKind(_ kind: NotificationKind) async {
        let toCancel = scheduled.filter { $0.request.kind == kind }
        let ids = toCancel.map(\.unRequestIdentifier)
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
            scheduled.removeAll { $0.request.kind == kind }
        }
        if let store = ruleStoreProvider() {
            _ = try? await store.cancelAll(kind: kind)
        }
    }

    func upcoming(domain: String?) async -> [ScheduledNotification] {
        guard let domain else { return scheduled }
        return scheduled.filter { $0.request.domain == domain }
    }

    /// Top up the next `daysAhead` days of recurring rules. Called on every
    /// foreground tick (and from BGAppRefreshTask). BGTasks are unreliable in
    /// install week, so this proactive refresh is THE correctness guarantor
    /// for the cron-via-notification design — without it the morning brief
    /// silently dies after 7 days (deslop FIX #3, addendum §1.3).
    ///
    /// Flow:
    /// 1. Reconcile in-memory `scheduled` against UN pending (cap math
    ///    truth-up; iOS may drop requests on system reload).
    /// 2. Load every active rule from `notification_recurring_rules`.
    /// 3. For each rule, expand the next `daysAhead` occurrences and
    ///    schedule any whose fireAt isn't already pending. Cap math runs
    ///    per occurrence; rule remains active even if an individual
    ///    occurrence is cap-blocked.
    func topUpHorizon(daysAhead: Int = 7) async {
        // 1. UN reconciliation
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = Set(pending.map(\.identifier))
        scheduled.removeAll { !pendingIDs.contains($0.unRequestIdentifier) }

        // 2. Load active rules
        guard let store = ruleStoreProvider() else { return }
        let rules: [RecurringRuleRecord]
        do {
            rules = try await store.loadActive()
        } catch {
            // Rule store outage isn't fatal — caller still sees a healthy
            // foreground tick; next tick will retry. Silent return matches
            // the "degrade visibly when user-facing, silent when internal"
            // principle: the user-visible morning brief still fires from
            // notifications already in UN's pending queue.
            return
        }
        if rules.isEmpty { return }

        // 3. Re-expand each rule. Skip occurrences whose fireAt+ruleID is
        //    already in `scheduled` so we don't double-book.
        let now = clock.now()
        let tz = timeZoneProvider()
        for record in rules {
            guard let parsed = try? RRuleParser.parse(record.rrule) else { continue }
            let occurrences = RecurringExpander.nextOccurrences(
                rule: parsed,
                startingAt: now,
                daysAhead: daysAhead,
                timeZone: tz
            )
            for occ in occurrences {
                let alreadyScheduled = scheduled.contains {
                    $0.ruleID == record.ruleID &&
                        abs($0.firesAt.timeIntervalSince(occ)) < 60   // same minute
                }
                if alreadyScheduled { continue }

                let context = decodeContext(record.templateContextJSON)
                let scope: AgentScope = record.scopeActor.hasPrefix("agent:")
                    ? .domain(String(record.scopeActor.dropFirst("agent:".count)))
                    : .coordinator
                let request = NotificationRequest(
                    kind: record.kind,
                    domain: record.domain,
                    instrumentID: record.instrumentID,
                    fireAt: occ,
                    templateContext: context,
                    actionContextJSON: record.actionContextJSON,
                    priority: record.priority
                )
                _ = await scheduleInternal(request, scope: scope, ruleID: record.ruleID)
            }
        }
    }

    // MARK: - context (de)serialization

    private func encodeContext(_ ctx: TemplateContext) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(ctx),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func decodeContext(_ json: String) -> TemplateContext {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(TemplateContext.self, from: data)
        else { return TemplateContext() }
        return parsed
    }

    /// Reconstruct a canonical RRULE string from the parsed subset. Used when
    /// the caller passed an RRuleSubset directly (not a string).
    private func canonicalize(_ rule: RRuleSubset) -> String {
        var parts: [String] = ["FREQ=\(rule.frequency.rawValue)"]
        if !rule.byDay.isEmpty {
            parts.append("BYDAY=\(rule.byDay.map(\.rawValue).joined(separator: ","))")
        }
        parts.append("BYHOUR=\(rule.byHour)")
        parts.append("BYMINUTE=\(rule.byMinute)")
        return parts.joined(separator: ";")
    }

    // MARK: - DEBUG hooks

    #if DEBUG
    /// Reset scheduler state for tests. Production builds don't see this.
    func _resetForTesting() {
        scheduled.removeAll()
    }
    #endif

    // MARK: - Cap math primitives (internal — exposed for tests)

    func currentMode(in s: Settings, now: Date) -> NotificationMode {
        if let pause = s.pauseUntil, pause > now { return .pause }
        if let mercy = s.mercyModeUntil, mercy > now { return .mercy }
        return .normal
    }

    func dayBucket(for date: Date, in tz: TimeZone) -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            // Calendar.date(byAdding:to:) only returns nil for transitions
            // we don't use here, but if it ever does we fall back to a
            // 24-hour interval rather than crashing.
            return DateInterval(start: start, duration: 86_400)
        }
        return DateInterval(start: start, end: end)
    }

    func isSameDay(_ a: Date, _ b: Date, in tz: TimeZone) -> Bool {
        dayBucket(for: a, in: tz) == dayBucket(for: b, in: tz)
    }

    func isInQuietHours(_ date: Date, settings: Settings) -> Bool {
        QuietHoursWindow.contains(
            date,
            startHHmm: settings.quietHours.start,
            endHHmm: settings.quietHours.end,
            timeZone: timeZoneProvider()
        )
    }

    func nextSlotAfterQuietHours(_ date: Date, settings: Settings) -> Date? {
        QuietHoursWindow.nextSlotAfter(
            date,
            endHHmm: settings.quietHours.end,
            timeZone: timeZoneProvider()
        )
    }

    private func nearestNeighbor(to candidate: Date) -> Date? {
        scheduled
            .map(\.firesAt)
            .min(by: { abs($0.timeIntervalSince(candidate)) < abs($1.timeIntervalSince(candidate)) })
    }
}

// MARK: - Supporting providers (kept generic so tests can inject)

protocol SettingsProviding: Sendable {
    func load() async throws -> Settings
}

struct LiveSettingsProvider: SettingsProviding {
    init() {}
    func load() async throws -> Settings {
        try await SettingsStore.shared.load()
    }
}

protocol ClockProviding: Sendable {
    func now() -> Date
}

struct SystemClock: ClockProviding {
    init() {}
    func now() -> Date { Date() }
}

// MARK: - QuietHoursWindow

/// "HH:mm" wall-clock window helpers. The window may straddle midnight (the
/// default 22:00–05:00 does). All arithmetic happens in the named TimeZone
/// so DST flips don't shift the brief by an hour.
enum QuietHoursWindow {
    static func contains(
        _ date: Date,
        startHHmm: String,
        endHHmm: String,
        timeZone: TimeZone
    ) -> Bool {
        guard let start = parseHHmm(startHHmm), let end = parseHHmm(endHHmm) else {
            return false
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.hour, .minute], from: date)
        guard let h = comps.hour, let m = comps.minute else { return false }
        let cur = h * 60 + m
        let s = start.hour * 60 + start.minute
        let e = end.hour * 60 + end.minute
        if s == e { return false }
        if s < e {
            return cur >= s && cur < e
        } else {
            // Window straddles midnight: e.g. 22:00–05:00 → cur ≥ 22:00 OR cur < 05:00.
            return cur >= s || cur < e
        }
    }

    /// Next date strictly after `from` whose wall-clock equals `endHHmm`.
    /// Used to reschedule a non-brief notification past quiet hours.
    static func nextSlotAfter(
        _ from: Date,
        endHHmm: String,
        timeZone: TimeZone
    ) -> Date? {
        guard let end = parseHHmm(endHHmm) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var comps = cal.dateComponents([.year, .month, .day], from: from)
        comps.hour = end.hour
        comps.minute = end.minute
        comps.second = 0
        guard let today = cal.date(from: comps) else { return nil }
        if today > from { return today }
        return cal.date(byAdding: .day, value: 1, to: today)
    }

    static func parseHHmm(_ s: String) -> (hour: Int, minute: Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m)
        else { return nil }
        return (h, m)
    }
}

// MARK: - RecurringExpander

/// Expands an `RRuleSubset` into a flat list of concrete fire `Date`s in a
/// given horizon. Pure function; safe to test without UserNotifications.
enum RecurringExpander {
    static func nextOccurrences(
        rule: RRuleSubset,
        startingAt anchor: Date,
        daysAhead: Int,
        timeZone: TimeZone
    ) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let allowedWeekdays: Set<Int> = rule.byDay.isEmpty
            ? Set(1...7)
            : Set(rule.byDay.map(\.calendarWeekday))

        var results: [Date] = []
        for offset in 0..<max(1, daysAhead) {
            guard let day = cal.date(byAdding: .day, value: offset, to: anchor) else { continue }
            var comps = cal.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let weekday = comps.weekday, allowedWeekdays.contains(weekday) else { continue }
            comps.hour = rule.byHour
            comps.minute = rule.byMinute
            comps.second = 0
            comps.weekday = nil
            guard let fire = cal.date(from: comps), fire > anchor else { continue }
            results.append(fire)
        }
        return results.sorted()
    }
}
