//
//  FollowupScheduler.swift
//  Steward — Track B
//
//  Implements the day-0 afternoon followup notification from
//  design/coordinator-empty-state-v2.md §6.
//
//  Body copy is NOT composed here (§1.3 + Pod D's hard reject #6). The
//  scheduler builds a `TemplateContext` + `NotificationRequest(kind:
//  .onboardingFollowup, ...)` and hands it to `NotificationScheduler` —
//  the canonical `NotificationTemplate.onboardingFollowup` arm owns the
//  three §6.2 variants.
//
//  Rule (verbatim from §6.1):
//   - Schedule (now + 5h 30m), clamped to [13:00, 17:00] local.
//   - If "now + 5h 30m" falls outside that window, snap to the nearest
//     edge — BUT if the snap would land in the past (we're already past
//     17:00), skip entirely. (Deslop S3.)
//   - `kind: onboardingFollowup`, `scheduled_by: coordinator`.
//   - Never repeats.
//   - If quiet hours overlap or pause is on, the scheduler suppresses;
//     we route the outcome to a typed `FollowupSchedulingOutcome`.
//

import Foundation

/// Outcome of a single onboarding-followup schedule attempt.
public enum FollowupSchedulingOutcome: Sendable, Equatable {
    case scheduled(notificationID: String, firesAt: Date)
    case skippedNoEngagement       // Branch C tail with neither domain nor event
    case skippedOutsideWindow      // now + 5h30m falls after 17:00 local
    case suppressedByQuietHours
    case suppressedByPause
    case capExceeded
    case systemError(reason: String)
}

/// Snapshot of what happened in the empty-state script — picks which of
/// the three §6.2 variants fires.
public struct OnboardingOutcome: Sendable, Equatable {
    public let spawnedDomainDisplayName: String?
    public let capturedAtLeastOneEvent: Bool

    public init(spawnedDomainDisplayName: String?, capturedAtLeastOneEvent: Bool) {
        self.spawnedDomainDisplayName = spawnedDomainDisplayName
        self.capturedAtLeastOneEvent = capturedAtLeastOneEvent
    }
}

/// Internal actor — only referenced from in-module call sites. We do not
/// expose `public init` because the default `NotificationScheduler.shared`
/// is internal; bumping the entire scheduler to public for one default
/// argument isn't worth the surface area.
actor FollowupScheduler {
    private let scheduler: NotificationScheduler
    private let clock: @Sendable () -> Date

    init(
        scheduler: NotificationScheduler = .shared,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scheduler = scheduler
        self.clock = clock
    }

    /// Computes the fire time and schedules the followup. Body copy is
    /// rendered by `NotificationTemplate` from the `TemplateContext` we
    /// build here — no string composition in this file.
    func schedule(
        outcome: OnboardingOutcome,
        timezone: TimeZone = .autoupdatingCurrent
    ) async -> FollowupSchedulingOutcome {
        if outcome.spawnedDomainDisplayName == nil && !outcome.capturedAtLeastOneEvent {
            return .skippedNoEngagement
        }

        let now = clock()
        guard let fireAt = Self.computeFireTime(now: now, timezone: timezone) else {
            // Past 17:00 already — snap would land in the past, so skip.
            return .skippedOutsideWindow
        }

        let context = TemplateContext(
            domainDisplayName: outcome.spawnedDomainDisplayName,
            capturedAtLeastOneEvent: outcome.capturedAtLeastOneEvent
        )

        let request = NotificationRequest(
            kind: .onboardingFollowup,
            domain: nil,
            instrumentID: nil,
            fireAt: fireAt,
            templateContext: context,
            actionContextJSON: #"{"open_tab":"chat","focus_input":true,"prime_mic":true}"#,
            priority: 0
        )

        let outcomeFromScheduler = await scheduler.schedule(request, scope: .coordinator)
        switch outcomeFromScheduler {
        case .scheduled(let id, let firesAt):
            return .scheduled(notificationID: id, firesAt: firesAt)
        case .suppressedByQuietHours:
            return .suppressedByQuietHours
        case .suppressedByPause:
            return .suppressedByPause
        case .capExceeded:
            return .capExceeded
        case .systemError(let reason):
            return .systemError(reason: reason)
        }
    }

    // MARK: - Pure helpers (unit-testable)

    /// (now + 5h30m), clamped to [13:00, 17:00] of the **same calendar day
    /// as `now`** in the given timezone. Per UXR v2 §6.1 + deslop S3:
    ///   - inside [13:00, 17:00) → return as-is
    ///   - candidate is before 13:00 of `now`'s day → snap forward to 13:00
    ///   - candidate is at/after 17:00 of `now`'s day → return nil; skip
    ///     entirely (snapping to 17:00 would land in the past; the day-0
    ///     followup belongs on day 0).
    public static func computeFireTime(now: Date, timezone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone

        let candidate = now.addingTimeInterval(5 * 3600 + 30 * 60)

        // Compute the day-0 window endpoints from `now`.
        let nowDayComps = cal.dateComponents([.year, .month, .day], from: now)
        var dayStart13 = nowDayComps
        dayStart13.hour = 13
        dayStart13.minute = 0
        dayStart13.second = 0
        var dayEnd17 = nowDayComps
        dayEnd17.hour = 17
        dayEnd17.minute = 0
        dayEnd17.second = 0
        guard let windowStart = cal.date(from: dayStart13),
              let windowEnd = cal.date(from: dayEnd17)
        else { return nil }

        if candidate >= windowStart && candidate < windowEnd {
            return candidate
        }
        if candidate < windowStart {
            // Before window on the same day → snap forward to 13:00.
            return windowStart
        }
        // candidate >= 17:00 of now's day → past-window; never snap into
        // the past, just skip.
        return nil
    }
}
