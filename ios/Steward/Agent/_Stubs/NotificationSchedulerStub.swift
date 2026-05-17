//
//  NotificationSchedulerStub.swift
//  Steward — Track B  /  DELETE AT MERGE
//
//  ⚠️  Pod D owns the canonical `NotificationScheduler` per addendum §1.3.
//  This file lives under `Agent/_Stubs/` and MUST be deleted when Pod D's
//  real implementation lands. Every public type below mirrors Pod D's
//  surface verbatim (see track-d-eventkit/ios/Steward/Notifications/
//  NotificationScheduler.swift + NotificationTemplate.swift) so that
//  Pod D's files replace this one with ZERO call-site changes in
//  FollowupScheduler.swift.
//
//  This stub does NOT touch UNUserNotificationCenter — that is hard reject
//  #8 territory (only Pod D's real scheduler is allowed to call
//  `UNUserNotificationCenter.add`). The stub just enqueues a row into the
//  `notifications` table inside a single `db.write { }` block so the
//  audit history exists when Pod D's scheduler comes online and drains
//  the table.
//
//  ----------------------------------------------------------------------
//  Pod D coordination: the `.onboardingFollowup` NotificationKind case
//  and `TemplateContext.capturedAtLeastOneEvent` field are NEW; they
//  exist here so Track B's standalone build works today. Sent impl-track-d
//  a SendMessage with the verbatim §6.2 render arm; at merge, Pod D's
//  template gets these additions and this stub disappears. If Pod D
//  hasn't added them yet at merge, team-lead applies the patch in the
//  message before deleting the stub.
//

import Foundation
import GRDB

// MARK: - Public types from §1.3 (verbatim shape to match Pod D)

public enum NotificationKind: String, Codable, Sendable, CaseIterable {
    case morningBrief        = "morningBrief"
    case windDown            = "windDown"
    case instrumentNudge     = "instrumentNudge"
    case commitmentDue       = "commitmentDue"
    case recoveryNudge       = "recoveryNudge"
    case onboardingFollowup  = "onboardingFollowup"  // UXR v2 §6 (new, see header)
}

public enum NotificationMode: String, Codable, Sendable, Equatable {
    case normal
    case mercy
    case pause
}

/// Substitution slots the template renderer reads. Templates fill from
/// these; nothing freeform.
public struct TemplateContext: Codable, Sendable, Equatable {
    public var domainDisplayName: String?
    public var instrumentName: String?
    public var commitmentTitle: String?
    public var lapseDays: Int?
    public var briefTimeDisplay: String?
    /// Followup variant selector (UXR v2 §6.2). True when the user logged
    /// at least one event during onboarding; selects the "How's X feeling"
    /// vs "You set up X" body.
    public var capturedAtLeastOneEvent: Bool?

    public init(
        domainDisplayName: String? = nil,
        instrumentName: String? = nil,
        commitmentTitle: String? = nil,
        lapseDays: Int? = nil,
        briefTimeDisplay: String? = nil,
        capturedAtLeastOneEvent: Bool? = nil
    ) {
        self.domainDisplayName = domainDisplayName
        self.instrumentName = instrumentName
        self.commitmentTitle = commitmentTitle
        self.lapseDays = lapseDays
        self.briefTimeDisplay = briefTimeDisplay
        self.capturedAtLeastOneEvent = capturedAtLeastOneEvent
    }
}

public enum CapReason: Sendable, Codable, Equatable {
    case dailyMax(currentCount: Int, max: Int)
    case minGap(lastFiredAt: Date, requiredGapMinutes: Int)
    case mercyModeCap
}

public enum ScheduleOutcome: Sendable, Equatable {
    case scheduled(notificationID: String, firesAt: Date)
    case capExceeded(reason: CapReason, nextAvailableSlot: Date?)
    case suppressedByQuietHours(rescheduledTo: Date?)
    case suppressedByPause
    /// Distinct from `capExceeded` — a system-level failure (UN.add threw,
    /// settings outage, DB write failed). Pod D's deslop FIX #6/#7.
    case systemError(reason: String)
}

public enum AgentScope: Sendable, Codable, Equatable {
    case coordinator
    case domain(String)

    public var dbScheduledBy: String {
        switch self {
        case .coordinator:        return "coordinator"
        case .domain(let d):      return "agent:\(d)"
        }
    }
}

public struct NotificationRequest: Codable, Sendable, Equatable {
    public var kind: NotificationKind
    public var domain: String?
    public var instrumentID: String?
    public var fireAt: Date
    public var templateContext: TemplateContext
    /// Opaque JSON the tap handler reads to drive a one-turn coordinator
    /// response. Templates cannot read it — bodies stay deterministic.
    public var actionContextJSON: String?
    /// Tie-breaker for cap math (higher = more important).
    public var priority: Int

    public init(
        kind: NotificationKind,
        domain: String? = nil,
        instrumentID: String? = nil,
        fireAt: Date,
        templateContext: TemplateContext,
        actionContextJSON: String? = nil,
        priority: Int = 0
    ) {
        self.kind = kind
        self.domain = domain
        self.instrumentID = instrumentID
        self.fireAt = fireAt
        self.templateContext = templateContext
        self.actionContextJSON = actionContextJSON
        self.priority = priority
    }
}

// MARK: - NotificationTemplate (stub matching Pod D)

/// Stub template. The §6.2 `.onboardingFollowup` arm uses UXR v2 verbatim
/// copy. Pod D's real `NotificationTemplate` replaces this; the signature
/// is identical so FollowupScheduler's call site is unchanged.
public enum NotificationTemplate {
    public struct Rendered: Sendable, Equatable {
        public let title: String
        public let body: String
        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    public static func render(
        kind: NotificationKind,
        mode: NotificationMode,
        context: TemplateContext
    ) -> Rendered {
        switch kind {
        case .morningBrief:
            return Rendered(title: "Good morning",
                            body: "Here's what's queued for \(context.briefTimeDisplay ?? "this morning").")
        case .windDown:
            return Rendered(title: "Wind-down", body: "Want to close out the day?")
        case .instrumentNudge:
            let n = context.instrumentName ?? "your instrument"
            return Rendered(title: "Quick check-in", body: "When you have a moment: \(n).")
        case .commitmentDue:
            let t = context.commitmentTitle ?? "your commitment"
            return Rendered(title: "Coming up", body: t)
        case .recoveryNudge:
            let d = context.domainDisplayName ?? "this area"
            return Rendered(title: "Whenever you're ready",
                            body: "Pick this back up in \(d) when it suits you.")
        case .onboardingFollowup:
            return onboardingFollowup(context: context)
        }
    }

    /// UXR v2 §6.2 verbatim. Pod D's real template should match this
    /// exactly. Mercy + pause modes share copy: §6.3 anti-shame applies
    /// equally across modes for this kind.
    private static func onboardingFollowup(context: TemplateContext) -> Rendered {
        let captured = context.capturedAtLeastOneEvent ?? false
        if let name = context.domainDisplayName {
            if captured {
                return Rendered(
                    title: "Steward",
                    body: "How's \(name) feeling? Anything to log — or nothing's fine too."
                )
            }
            return Rendered(
                title: "Steward",
                body: "You set up the \(name) team this morning. Anything to log? Hold the mic and just talk."
            )
        }
        return Rendered(
            title: "Steward",
            body: "Anything else to catch from today? Two seconds of voice works."
        )
    }
}

// MARK: - The stub actor

/// Stub — same surface as Pod D's canonical, no UN registration.
///
/// Hard rule: this file MUST NOT call `UNUserNotificationCenter.add`. Pod
/// D's real implementation handles UN. The stub just writes the row so the
/// audit chain is intact when the real scheduler comes online and drains.
public actor NotificationScheduler {
    public static let shared = NotificationScheduler()

    private let provider: DatabaseProvider
    private let idGen: @Sendable () -> String

    // Internal init: parameter types (`DatabaseProvider`) are internal in
    // Track A's scaffold; `public` would warn. Same-target callers don't
    // need broader visibility.
    init(
        provider: DatabaseProvider = .shared,
        idGen: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.provider = provider
        self.idGen = idGen
    }

    /// Per §1.3. The stub renders the body via NotificationTemplate (so
    /// the audit row carries the actual user-visible copy) and writes
    /// the notifications table row. Pod D's canonical replaces the body
    /// with full cap math + UN registration.
    @discardableResult
    public func schedule(
        _ req: NotificationRequest,
        scope: AgentScope
    ) async -> ScheduleOutcome {
        let id = idGen()
        // Mode is read from SettingsStore inside Pod D's canonical actor;
        // this shim assumes .normal until that lands.
        let rendered = NotificationTemplate.render(
            kind: req.kind,
            mode: .normal,
            context: req.templateContext
        )
        do {
            let db = try await provider.database()
            try await db.write { dbase in
                try dbase.execute(
                    sql: """
                        INSERT INTO notifications (
                            notification_id, scheduled_for, domain, instrument_id,
                            kind, title, body, action_context_json, scheduled_by
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        id,
                        Int64(req.fireAt.timeIntervalSince1970 * 1000),
                        req.domain,
                        req.instrumentID,
                        req.kind.rawValue,
                        rendered.title,
                        rendered.body,
                        req.actionContextJSON,
                        scope.dbScheduledBy,
                    ]
                )
            }
            return .scheduled(notificationID: id, firesAt: req.fireAt)
        } catch {
            return .systemError(reason: "stub_db_write_failed: \(error)")
        }
    }
}
