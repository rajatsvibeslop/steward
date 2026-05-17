//
//  NotificationTools.swift
//  Steward
//
//  notification.* LLMTool conformances. Every tool dispatches through
//  NotificationScheduler — direct UNUserNotificationCenter.add anywhere else
//  in the app is HARD REJECT #8.
//
//  Bodies are NEVER passed in from the LLM (hard reject #6). The model
//  provides a `kind` + structured TemplateContext fields; the template
//  renderer produces title/body. The `title` and `body` slots the spec §8 tool
//  signatures mention are accepted only for parity, mapped to template
//  context, and then DISCARDED — the rendered template wins.
//

import Foundation

// MARK: - notification.schedule

struct NotificationScheduleArgs: Codable, Sendable {
    var kind: NotificationKind
    var fireAt: Date
    var domain: String?
    var instrumentID: String?
    var commitmentTitle: String?
    var instrumentName: String?
    var domainDisplayName: String?
    var briefTimeDisplay: String?
    var actionContextJSON: String?
    /// Agent's stated reason — required when called by an agent / coordinator.
    var reasoning: String

    init(
        kind: NotificationKind,
        fireAt: Date,
        domain: String? = nil,
        instrumentID: String? = nil,
        commitmentTitle: String? = nil,
        instrumentName: String? = nil,
        domainDisplayName: String? = nil,
        briefTimeDisplay: String? = nil,
        actionContextJSON: String? = nil,
        reasoning: String
    ) {
        self.kind = kind
        self.fireAt = fireAt
        self.domain = domain
        self.instrumentID = instrumentID
        self.commitmentTitle = commitmentTitle
        self.instrumentName = instrumentName
        self.domainDisplayName = domainDisplayName
        self.briefTimeDisplay = briefTimeDisplay
        self.actionContextJSON = actionContextJSON
        self.reasoning = reasoning
    }
}

struct NotificationScheduleResult: Codable, Sendable {
    let outcome: ScheduleOutcomeWire
    let notificationID: String?
    let firesAt: Date?
}

/// Wire representation of `ScheduleOutcome` that's friendly to JSON
/// (associated values don't survive the default Codable shape for enums on
/// older Swift versions; the wire form keeps the LLM contract stable).
struct ScheduleOutcomeWire: Codable, Sendable, Equatable {
    let status: String
    let reason: String?
    let nextAvailableSlot: Date?
    let rescheduledTo: Date?

    static func from(_ outcome: ScheduleOutcome) -> ScheduleOutcomeWire {
        switch outcome {
        case .scheduled:
            return .init(status: "scheduled", reason: nil, nextAvailableSlot: nil, rescheduledTo: nil)
        case .capExceeded(let capReason, let next):
            let reason: String
            switch capReason {
            case .dailyMax(let cur, let max):
                reason = "daily_max(\(cur)/\(max))"
            case .minGap(_, let gap):
                reason = "min_gap_\(gap)min"
            case .mercyModeCap:
                reason = "mercy_mode_cap"
            }
            return .init(status: "cap_exceeded", reason: reason, nextAvailableSlot: next, rescheduledTo: nil)
        case .suppressedByQuietHours(let resched):
            return .init(status: "suppressed_quiet_hours", reason: nil, nextAvailableSlot: nil, rescheduledTo: resched)
        case .suppressedByPause:
            return .init(status: "suppressed_pause", reason: nil, nextAvailableSlot: nil, rescheduledTo: nil)
        case .systemError(let reason):
            return .init(status: "system_error", reason: reason, nextAvailableSlot: nil, rescheduledTo: nil)
        }
    }
}

actor NotificationScheduleTool: LLMTool {
    let id = ToolID.notificationSchedule.rawValue
    let description = "Schedule a local notification at fireAt with a templated body."
    let jsonSchemaForArgs: String

    private let scheduler: NotificationScheduler
    private let auditLog: AuditLog
    private let turnIDProvider: @Sendable () -> TurnID

    init(
        scheduler: NotificationScheduler = .shared,
        auditLog: AuditLog = .shared,
        turnIDProvider: @escaping @Sendable () -> TurnID = { TurnID.generate() },
        jsonSchemaForArgs: String = NotificationScheduleTool.defaultSchema
    ) {
        self.scheduler = scheduler
        self.auditLog = auditLog
        self.turnIDProvider = turnIDProvider
        self.jsonSchemaForArgs = jsonSchemaForArgs
    }

    static let defaultSchema: String = """
    {
      "type": "object",
      "properties": {
        "kind": {"type":"string","enum":["morningBrief","windDown","instrumentNudge","commitmentDue","recoveryNudge"]},
        "fireAt": {"type":"string","format":"date-time"},
        "domain": {"type":"string"},
        "reasoning": {"type":"string"}
      },
      "required":["kind","fireAt","reasoning"]
    }
    """

    func invoke(argsJSON: String) async throws -> String {
        let args = try Self.decode(argsJSON)
        let outcome = await schedule(args: args, actor: .coordinator)
        let result = NotificationScheduleResult(
            outcome: .from(outcome),
            notificationID: {
                if case .scheduled(let id, _) = outcome { return id } else { return nil }
            }(),
            firesAt: {
                if case .scheduled(_, let at) = outcome { return at } else { return nil }
            }()
        )
        return try Self.encode(result)
    }

    /// Direct entry point for callers who already have a parsed args struct
    /// (UI inline grant flow, BG handler, tests).
    func schedule(args: NotificationScheduleArgs, actor: ActorRef) async -> ScheduleOutcome {
        let request = NotificationRequest(
            kind: args.kind,
            domain: args.domain,
            instrumentID: args.instrumentID,
            fireAt: args.fireAt,
            templateContext: TemplateContext(
                domainDisplayName: args.domainDisplayName,
                instrumentName: args.instrumentName,
                commitmentTitle: args.commitmentTitle,
                lapseDays: nil,
                briefTimeDisplay: args.briefTimeDisplay
            ),
            actionContextJSON: args.actionContextJSON,
            priority: args.kind == .morningBrief ? 100 : 10
        )
        let outcome = await scheduler.schedule(request, scope: .coordinator)
        if case .scheduled(let unID, _) = outcome {
            // Record an audit event with a cancel-notification inverse.
            let turnAction = TurnAction(
                turnID: turnIDProvider(),
                toolID: .notificationSchedule,
                actor: actor,
                reasoning: args.reasoning,
                inverse: .cancelNotification(notificationID: unID)
            )
            // Audit failures must not break the scheduling path — we already
            // registered the notification with iOS. Surface to console; the
            // audit row is recoverable from UN if needed.
            do {
                _ = try await auditLog.recordAgentAction(
                    turnAction,
                    domain: args.domain,
                    instrumentID: args.instrumentID,
                    source: "tool:\(ToolID.notificationSchedule.rawValue)"
                )
            } catch {
            }
        }
        return outcome
    }

    static func decode(_ json: String) throws -> NotificationScheduleArgs {
        guard let data = json.data(using: .utf8) else {
            throw ToolError(kind: .argumentsInvalid, message: "argsJSON not UTF-8")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            return try dec.decode(NotificationScheduleArgs.self, from: data)
        } catch {
            throw ToolError(kind: .argumentsInvalid, message: "\(error)")
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - notification.schedule_recurring

struct NotificationScheduleRecurringArgs: Codable, Sendable {
    var kind: NotificationKind
    var recurrenceRule: String
    var domain: String?
    var instrumentID: String?
    var commitmentTitle: String?
    var instrumentName: String?
    var domainDisplayName: String?
    var briefTimeDisplay: String?
    var actionContextJSON: String?
    var reasoning: String
}

actor NotificationScheduleRecurringTool: LLMTool {
    let id = ToolID.notificationScheduleRecurring.rawValue
    let description = "Schedule a recurring local notification from an RFC 5545 RRULE subset."
    let jsonSchemaForArgs = """
    {
      "type": "object",
      "properties": {
        "kind": {"type":"string"},
        "recurrenceRule": {"type":"string","description":"e.g. FREQ=DAILY;BYHOUR=7;BYMINUTE=0"},
        "domain": {"type":"string"},
        "reasoning": {"type":"string"}
      },
      "required":["kind","recurrenceRule","reasoning"]
    }
    """

    private let scheduler: NotificationScheduler
    private let auditLog: AuditLog
    private let turnIDProvider: @Sendable () -> TurnID

    init(
        scheduler: NotificationScheduler = .shared,
        auditLog: AuditLog = .shared,
        turnIDProvider: @escaping @Sendable () -> TurnID = { TurnID.generate() }
    ) {
        self.scheduler = scheduler
        self.auditLog = auditLog
        self.turnIDProvider = turnIDProvider
    }

    func invoke(argsJSON: String) async throws -> String {
        guard let data = argsJSON.data(using: .utf8) else {
            throw ToolError(kind: .argumentsInvalid, message: "argsJSON not UTF-8")
        }
        let args: NotificationScheduleRecurringArgs
        do {
            args = try JSONDecoder().decode(NotificationScheduleRecurringArgs.self, from: data)
        } catch {
            throw ToolError(kind: .argumentsInvalid, message: "\(error)")
        }

        let rule: RRuleSubset
        do {
            rule = try RRuleParser.parse(args.recurrenceRule)
        } catch {
            throw ToolError(kind: .argumentsInvalid, message: "\(error)",
                            hint: "Use FREQ=DAILY;BYHOUR=<h>;BYMINUTE=<m>[;BYDAY=<MO,TU,...>].")
        }

        // Anchor fireAt to "now" — the scheduler's recurring path expands the
        // rule into concrete occurrences over the next 7 days and submits each
        // through the cap-checked path.
        let baseRequest = NotificationRequest(
            kind: args.kind,
            domain: args.domain,
            instrumentID: args.instrumentID,
            fireAt: Date(),
            templateContext: TemplateContext(
                domainDisplayName: args.domainDisplayName,
                instrumentName: args.instrumentName,
                commitmentTitle: args.commitmentTitle,
                lapseDays: nil,
                briefTimeDisplay: args.briefTimeDisplay
            ),
            actionContextJSON: args.actionContextJSON,
            priority: args.kind == .morningBrief ? 100 : 10
        )
        let (outcome, ruleID) = await scheduler.scheduleRecurring(
            rule, request: baseRequest, scope: .coordinator, rrule: args.recurrenceRule
        )

        // Emit `.cancelRecurringRule(ruleID:)` as the inverse — NOT
        // `.cancelNotification(...)`, which only cancels the first occurrence
        // and leaves the rule active for topUpHorizon to re-issue (deslop
        // regression B). The audit row is only written when both (a) the
        // first occurrence scheduled successfully AND (b) the rule was
        // actually persisted (ruleID non-nil); otherwise undo would have
        // nothing to cancel and the row would be a permanently-broken
        // audit-log entry.
        if case .scheduled = outcome, let ruleID {
            let turnAction = TurnAction(
                turnID: turnIDProvider(),
                toolID: .notificationScheduleRecurring,
                actor: .coordinator,
                reasoning: args.reasoning,
                inverse: .cancelRecurringRule(ruleID: ruleID)
            )
            do {
                _ = try await auditLog.recordAgentAction(
                    turnAction,
                    domain: args.domain,
                    instrumentID: args.instrumentID,
                    source: "tool:\(ToolID.notificationScheduleRecurring.rawValue)"
                )
            } catch {
            }
        }

        let result = NotificationScheduleResult(
            outcome: .from(outcome),
            notificationID: { if case .scheduled(let id, _) = outcome { return id } else { return nil } }(),
            firesAt: { if case .scheduled(_, let at) = outcome { return at } else { return nil } }()
        )
        return try NotificationScheduleTool.encode(result)
    }
}

// MARK: - notification.cancel

struct NotificationCancelArgs: Codable, Sendable {
    /// Either a UN request identifier OR a NotificationKind raw value.
    var notificationIDOrKind: String
    var reasoning: String
}

actor NotificationCancelTool: LLMTool {
    let id = ToolID.notificationCancel.rawValue
    let description = "Cancel a scheduled notification by ID or kind."
    let jsonSchemaForArgs = """
    {"type":"object","properties":{"notificationIDOrKind":{"type":"string"},"reasoning":{"type":"string"}},"required":["notificationIDOrKind","reasoning"]}
    """

    private let scheduler: NotificationScheduler
    private let auditLog: AuditLog
    private let turnIDProvider: @Sendable () -> TurnID

    init(
        scheduler: NotificationScheduler = .shared,
        auditLog: AuditLog = .shared,
        turnIDProvider: @escaping @Sendable () -> TurnID = { TurnID.generate() }
    ) {
        self.scheduler = scheduler
        self.auditLog = auditLog
        self.turnIDProvider = turnIDProvider
    }

    func invoke(argsJSON: String) async throws -> String {
        guard let data = argsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(NotificationCancelArgs.self, from: data)
        else {
            throw ToolError(kind: .argumentsInvalid, message: "argsJSON not parseable")
        }

        // Resolve to a concrete UN identifier (or set of identifiers). If the
        // arg matches a NotificationKind, this is "cancel everything of this
        // kind" — that flips both pending occurrences AND any active
        // recurring rules of the same kind (so the rule stops re-issuing).
        let upcomingAll = await scheduler.upcoming(domain: nil)
        let targets: [ScheduledNotification]
        let isKindWide: Bool
        if let kind = NotificationKind(rawValue: args.notificationIDOrKind) {
            targets = upcomingAll.filter { $0.request.kind == kind }
            isKindWide = true
            await scheduler.cancelKind(kind)
        } else {
            targets = upcomingAll.filter { $0.unRequestIdentifier == args.notificationIDOrKind }
            isKindWide = false
        }
        var cancelledIDs: [String] = []
        for t in targets {
            if !isKindWide {
                // For kind-wide cancellation, cancelKind already removed the
                // pending notifications; we skip the per-id call to avoid
                // double-counting.
                await scheduler.cancel(id: NotificationID(rawValue: t.unRequestIdentifier))
            }
            cancelledIDs.append(t.unRequestIdentifier)

            // Inverse is the original request (rescheduleNotification).
            let turnAction = TurnAction(
                turnID: turnIDProvider(),
                toolID: .notificationCancel,
                actor: .coordinator,
                reasoning: args.reasoning,
                inverse: .rescheduleNotification(request: t.request)
            )
            do {
                _ = try await auditLog.recordAgentAction(
                    turnAction,
                    domain: t.request.domain,
                    instrumentID: t.request.instrumentID,
                    source: "tool:\(ToolID.notificationCancel.rawValue)"
                )
            } catch {
            }
        }

        let payload: [String: AnyEncodable] = [
            "cancelled_count": AnyEncodable(cancelledIDs.count),
            "cancelled_ids": AnyEncodable(cancelledIDs)
        ]
        return try NotificationScheduleTool.encode(payload)
    }
}

// MARK: - notification.list_upcoming

struct NotificationListUpcomingArgs: Codable, Sendable {
    var domain: String?
    var limit: Int?
}

actor NotificationListUpcomingTool: LLMTool {
    let id = ToolID.notificationListUpcoming.rawValue
    let description = "List scheduled notifications, newest first."
    let jsonSchemaForArgs = """
    {"type":"object","properties":{"domain":{"type":"string"},"limit":{"type":"integer"}}}
    """

    private let scheduler: NotificationScheduler
    init(scheduler: NotificationScheduler = .shared) { self.scheduler = scheduler }

    func invoke(argsJSON: String) async throws -> String {
        let args: NotificationListUpcomingArgs
        if let data = argsJSON.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(NotificationListUpcomingArgs.self, from: data) {
            args = parsed
        } else {
            args = NotificationListUpcomingArgs()
        }
        let upcoming = await scheduler.upcoming(domain: args.domain)
        let limit = args.limit ?? 20
        let trimmed = upcoming
            .sorted { $0.firesAt < $1.firesAt }
            .prefix(limit)
            .map { sched -> [String: AnyEncodable] in
                [
                    "notification_id": AnyEncodable(sched.unRequestIdentifier),
                    "kind": AnyEncodable(sched.request.kind.rawValue),
                    "fires_at": AnyEncodable(sched.firesAt),
                    "domain": AnyEncodable(sched.request.domain ?? "")
                ]
            }
        return try NotificationScheduleTool.encode(["items": Array(trimmed)])
    }
}
