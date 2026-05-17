//
//  ToolScope.swift
//  Steward — Track B
//
//  Typed tool surface from addendum §1.8. Replaces string-keyed dispatch
//  for which agents can call which tools.
//
//  Track C implements concrete tools; they conform to `LLMTool` (see
//  LLMSession.swift) and look up their `ToolID` from this enum. Domain
//  agents get a constrained subset via `fixedArgs` (e.g. Money agent's
//  `commitment.create` is forced to `domain="money"`).
//

import Foundation

/// Every tool the model can call. CaseIterable so `ToolScope.all` is
/// derivable; the raw value is the dotted ID that flows over the wire.
///
/// Hard reject #9: no `if kind == "running_accumulator"` style dispatch.
/// All switches on this enum MUST be exhaustive without `default:`.
public enum ToolID: String, Sendable, Codable, CaseIterable, Hashable {
    // Capture and logging
    case eventCapture        = "event.capture"
    case eventList           = "event.list"
    case eventRecentSummary  = "event.recent_summary"

    // Instruments
    case instrumentCreate           = "instrument.create"
    case instrumentList             = "instrument.list"
    case instrumentRead             = "instrument.read"
    case instrumentApplyEvent       = "instrument.apply_event"
    case instrumentUpdateDefinition = "instrument.update_definition"
    case instrumentArchive          = "instrument.archive"

    // Commitments
    case commitmentCreate   = "commitment.create"
    case commitmentList     = "commitment.list"
    case commitmentComplete = "commitment.complete"
    case commitmentAbandon  = "commitment.abandon"
    case commitmentSnooze   = "commitment.snooze"

    // Memory
    case memorySave       = "memory.save"
    case memorySearch     = "memory.search"
    case memoryForget     = "memory.forget"
    case memoryStrengthen = "memory.strengthen"
    case memoryListRecent = "memory.list_recent"

    // Notifications
    case notificationSchedule          = "notification.schedule"
    case notificationScheduleRecurring = "notification.schedule_recurring"
    case notificationCancel            = "notification.cancel"
    case notificationListUpcoming      = "notification.list_upcoming"

    // Calendar + Reminders
    case calendarRead     = "calendar.read"
    case calendarWrite    = "calendar.write"
    case calendarModify   = "calendar.modify"
    case calendarDelete   = "calendar.delete"
    case reminderCreate   = "reminder.create"
    case reminderComplete = "reminder.complete"
    case reminderList     = "reminder.list"

    // CSV mirror
    case csvMirrorEnsureInstrumentFile = "csv_mirror.ensure_instrument_file"
    case csvMirrorSyncNow              = "csv_mirror.sync_now"
    case csvMirrorReadOverrides        = "csv_mirror.read_overrides"

    // Domain management
    case domainCreate       = "domain.create"
    case domainList         = "domain.list"
    case domainUpdatePrompt = "domain.update_prompt"
    case domainArchive      = "domain.archive"

    // Cross-agent
    case agentHandoff       = "agent.handoff"
    case agentCrossConsult  = "agent.cross_consult"

    // Web (deferred but exposed)
    case webSearch = "web.search"

    // Settings + safety
    case mercyModeEngage = "mercy_mode.engage"
    case pauseEngage     = "pause.engage"
    case quietHoursSet   = "quiet_hours.set"
}

/// Boolean-ish JSON value type wide enough to hold the literals a tool
/// scope's `fixedArgs` typically pins (strings, ints, bools). Used as the
/// arg value vocabulary for both whitelist and pin.
///
/// Keeping this narrow rather than wrapping the whole JSON spec — domain
/// agents typically pin `domain="health"` and similar scalar overrides.
public enum AnyCodableScalar: Sendable, Codable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case double(Double)
    case null
}

public struct ArgConstraints: Sendable, Codable, Equatable {
    public var fixedArgs: [String: AnyCodableScalar]
    public var allowedValues: [String: [AnyCodableScalar]]

    public init(
        fixedArgs: [String: AnyCodableScalar] = [:],
        allowedValues: [String: [AnyCodableScalar]] = [:]
    ) {
        self.fixedArgs = fixedArgs
        self.allowedValues = allowedValues
    }

    public static let none = ArgConstraints()
}

public struct ToolScope: Sendable, Codable, Equatable {
    public var allowedTools: Set<ToolID>
    public var argConstraints: [ToolID: ArgConstraints]

    public init(allowedTools: Set<ToolID>, argConstraints: [ToolID: ArgConstraints] = [:]) {
        self.allowedTools = allowedTools
        self.argConstraints = argConstraints
    }

    /// Coordinator scope: every tool, no arg constraints. The coordinator
    /// is allowed to do anything; domain agents narrow this down.
    public static let coordinatorAll = ToolScope(
        allowedTools: Set(ToolID.allCases),
        argConstraints: [:]
    )

    /// Build a domain-scoped subset. Domain agents:
    ///   - own their domain's events, instruments, commitments, memory
    ///   - cannot create new domains or hand off again
    ///   - cannot directly engage app-wide safety (mercy/pause/quiet_hours)
    ///   - get `fixedArgs["domain"] = domain` on every tool that takes one
    public static func domain(_ domain: String) -> ToolScope {
        let allowed: Set<ToolID> = [
            .eventCapture, .eventList, .eventRecentSummary,
            .instrumentCreate, .instrumentList, .instrumentRead,
            .instrumentApplyEvent, .instrumentUpdateDefinition, .instrumentArchive,
            .commitmentCreate, .commitmentList, .commitmentComplete,
            .commitmentAbandon, .commitmentSnooze,
            .memorySave, .memorySearch, .memoryStrengthen, .memoryListRecent,
            .notificationSchedule, .notificationCancel, .notificationListUpcoming,
            .calendarRead, .reminderList, .reminderCreate,
            .csvMirrorEnsureInstrumentFile,
        ]
        let pinDomain = ArgConstraints(fixedArgs: ["domain": .string(domain)])
        let constraints: [ToolID: ArgConstraints] = [
            .eventCapture: pinDomain,
            .eventList: pinDomain,
            .eventRecentSummary: pinDomain,
            .instrumentCreate: pinDomain,
            .instrumentList: pinDomain,
            .commitmentCreate: pinDomain,
            .commitmentList: pinDomain,
            .memorySave: pinDomain,
            .memorySearch: pinDomain,
            .memoryListRecent: pinDomain,
            .notificationSchedule: pinDomain,
            .notificationListUpcoming: pinDomain,
        ]
        return ToolScope(allowedTools: allowed, argConstraints: constraints)
    }
}

/// Errors `ToolGuard.validate` raises. Surfaced to the model as a
/// structured `tool_error` so the LLM can route around the denial rather
/// than the framework throwing.
public enum ToolGuardError: Error, CustomStringConvertible, Equatable {
    case toolOutOfScope(ToolID)
    case argMissing(ToolID, argName: String)
    case argPinViolation(ToolID, argName: String, expected: AnyCodableScalar)
    case argNotInWhitelist(ToolID, argName: String)
    case argsNotObject(ToolID)

    public var description: String {
        switch self {
        case .toolOutOfScope(let t):
            return "Tool \(t.rawValue) is not in this agent's scope."
        case .argMissing(let t, let arg):
            return "Tool \(t.rawValue) called without required arg '\(arg)'."
        case .argPinViolation(let t, let arg, let exp):
            return "Tool \(t.rawValue) arg '\(arg)' must equal pinned value \(exp)."
        case .argNotInWhitelist(let t, let arg):
            return "Tool \(t.rawValue) arg '\(arg)' is not in the allowed-values whitelist."
        case .argsNotObject(let t):
            return "Tool \(t.rawValue) args must be a JSON object."
        }
    }
}

public enum ToolGuard {
    /// Validates args before dispatch. Throws on violation so the caller
    /// can surface a structured error back to the LLM. Args are passed
    /// as a parsed `[String: AnyCodableScalar]` dictionary; the parsing is
    /// the caller's responsibility (FoundationModels does it for free via
    /// `@Generable`; MockLLMSession decodes manually for its fixtures).
    public static func validate(
        _ toolID: ToolID,
        args: [String: AnyCodableScalar],
        scope: ToolScope
    ) throws {
        guard scope.allowedTools.contains(toolID) else {
            throw ToolGuardError.toolOutOfScope(toolID)
        }
        let constraints = scope.argConstraints[toolID] ?? .none
        for (name, expected) in constraints.fixedArgs {
            guard let actual = args[name] else {
                throw ToolGuardError.argMissing(toolID, argName: name)
            }
            if actual != expected {
                throw ToolGuardError.argPinViolation(toolID, argName: name, expected: expected)
            }
        }
        for (name, whitelist) in constraints.allowedValues {
            guard let actual = args[name] else { continue }
            if !whitelist.contains(actual) {
                throw ToolGuardError.argNotInWhitelist(toolID, argName: name)
            }
        }
    }
}
