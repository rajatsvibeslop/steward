//
//  NotificationTemplate.swift
//  Steward
//
//  HARD REJECT #6: LLM NEVER composes notification body strings. Templates own
//  the copy. The model picks `kind` + mode + template context vars — the
//  template renders the final user-facing strings.
//
//  Mode ∈ {normal, mercy, pause}:
//  - normal: standard copy
//  - mercy: softened copy ("if it feels okay…" / "small win idea")
//  - pause: there should be no body to render in pause mode at all — pause
//           suppresses every notification except calendar-driven hard ones.
//           If a render reaches us in pause mode, it's a deterministic fallback
//           so we don't crash; the suppressed notification still gets routed
//           through ScheduleOutcome.suppressedByPause upstream.
//

import Foundation

enum NotificationKind: String, Codable, Sendable, CaseIterable {
    case morningBrief
    case windDown
    case instrumentNudge
    case commitmentDue
    case recoveryNudge
    /// UXR v2 §6 day-0 onboarding followup (Pod B's FollowupScheduler).
    /// Fires once at now+5h30m clamped to [13:00, 17:00] local; body varies
    /// by whether the user captured at least one event since onboarding.
    case onboardingFollowup
}

enum NotificationMode: String, Codable, Sendable, Equatable {
    case normal
    case mercy
    case pause
}

/// Slots a tool call can fill into the template body without composing
/// freeform copy. Only the values listed here are substitutable.
struct TemplateContext: Codable, Sendable, Equatable {
    var domainDisplayName: String?
    var instrumentName: String?
    var commitmentTitle: String?
    var lapseDays: Int?
    /// User's local time string for the brief (already rendered to "7am"
    /// upstream — templates never format times themselves so DST behavior
    /// is consistent with the chat UI).
    var briefTimeDisplay: String?
    /// UXR v2 §6.2 followup-variant selector: did the user log at least one
    /// event between onboarding and the followup fire time? `nil` is
    /// treated as `false` so the no-domain / no-capture fallback wins
    /// when callers omit the field.
    var capturedAtLeastOneEvent: Bool?

    init(
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

/// Pure-function template renderer. No dependency on db / network / time —
/// callers pass everything in so the body is deterministic.
enum NotificationTemplate {
    struct Rendered: Sendable, Equatable {
        let title: String
        let body: String
    }

    static func render(
        kind: NotificationKind,
        mode: NotificationMode,
        context: TemplateContext
    ) -> Rendered {
        // The switch is intentionally exhaustive so adding a NotificationKind
        // forces the addendum-mandated copy review in this file.
        switch kind {
        case .morningBrief:
            return morningBrief(mode: mode, context: context)
        case .windDown:
            return windDown(mode: mode, context: context)
        case .instrumentNudge:
            return instrumentNudge(mode: mode, context: context)
        case .commitmentDue:
            return commitmentDue(mode: mode, context: context)
        case .recoveryNudge:
            return recoveryNudge(mode: mode, context: context)
        case .onboardingFollowup:
            return onboardingFollowup(mode: mode, context: context)
        }
    }

    // MARK: - Individual kind renderers

    /// Morning brief — only kind that fires in mercy mode, only kind that
    /// fires inside quiet hours (rescheduled to wake hour upstream if needed).
    private static func morningBrief(mode: NotificationMode, context: TemplateContext) -> Rendered {
        let timeDisplay = context.briefTimeDisplay ?? "this morning"
        switch mode {
        case .normal:
            return Rendered(
                title: "Good morning",
                body: "Here's what's queued for \(timeDisplay)."
            )
        case .mercy:
            return Rendered(
                title: "Good morning",
                body: "No pressure today — when you're ready, I'm here."
            )
        case .pause:
            // Pause mode should have suppressed this upstream, but render a
            // safe fallback so we never crash mid-tap.
            return Rendered(
                title: "Good morning",
                body: "Steward is paused. Tap to resume when you're ready."
            )
        }
    }

    private static func windDown(mode: NotificationMode, context: TemplateContext) -> Rendered {
        switch mode {
        case .normal:
            return Rendered(
                title: "Wind-down",
                body: "Want to close out the day?"
            )
        case .mercy:
            return Rendered(
                title: "Whenever you're ready",
                body: "Small win idea — log one thing you did today, if it feels okay."
            )
        case .pause:
            return Rendered(title: "Wind-down", body: "Steward is paused.")
        }
    }

    private static func instrumentNudge(mode: NotificationMode, context: TemplateContext) -> Rendered {
        let instrument = context.instrumentName ?? "your instrument"
        switch mode {
        case .normal:
            return Rendered(
                title: "Quick check-in",
                body: "When you have a moment: \(instrument)."
            )
        case .mercy:
            return Rendered(
                title: "If it feels okay",
                body: "\(instrument) — only if it's easy right now."
            )
        case .pause:
            return Rendered(title: "Check-in", body: "Steward is paused.")
        }
    }

    private static func commitmentDue(mode: NotificationMode, context: TemplateContext) -> Rendered {
        let title = context.commitmentTitle ?? "your commitment"
        switch mode {
        case .normal:
            return Rendered(
                title: "Coming up",
                body: title
            )
        case .mercy:
            return Rendered(
                title: "When ready",
                body: "\(title) — only when it feels manageable."
            )
        case .pause:
            return Rendered(
                title: "Coming up",
                body: title
            )
        }
    }

    private static func recoveryNudge(mode: NotificationMode, context: TemplateContext) -> Rendered {
        let domain = context.domainDisplayName ?? "this area"
        switch mode {
        case .normal:
            return Rendered(
                title: "Whenever you're ready",
                body: "Pick this back up in \(domain) when it suits you."
            )
        case .mercy:
            return Rendered(
                title: "No rush",
                body: "Small re-entry in \(domain) when it feels easy. No catch-up needed."
            )
        case .pause:
            return Rendered(title: "Whenever you're ready", body: "Steward is paused.")
        }
    }

    /// UXR v2 §6.2 — day-0 onboarding followup. Three deterministic variants
    /// keyed on (domain present?, captured at least one event?):
    ///   - has-domain + no-capture: prompt the user to log via voice.
    ///   - has-domain + captured:   low-affect check-in, opt-out tolerated.
    ///   - no-domain + captured:    "anything else from today?"
    /// Mercy and pause modes use the same body — UXR §6.3 bans shame
    /// language across all modes and the copy is already low-affect, so
    /// differentiating buys nothing.
    private static func onboardingFollowup(
        mode: NotificationMode,
        context: TemplateContext
    ) -> Rendered {
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
        // No-domain (rare; UXR script requires at least one domain by the
        // time this fires, but handle it defensively).
        return Rendered(
            title: "Steward",
            body: "Anything else to catch from today? Two seconds of voice works."
        )
    }
}
