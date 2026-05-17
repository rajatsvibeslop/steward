//
//  ToolCallSummaryBuilder.swift
//  Steward — Track E
//
//  Deterministic projection from a Pod B `LLMToolInvocation` (raw tool call
//  receipt) to a `ToolCallSummary` the Chat UI renders. The verb/object table
//  comes verbatim from `design/ui-specs.md` §1.3 — no LLM composition.
//
//  Switch on the typed `ToolID` enum (not on the wire string) so adding a new
//  tool is a compile error here until it gets a verb/object pair.
//

import Foundation

enum ToolCallSummaryBuilder {

    /// Project one raw invocation into a UI summary. `actorLabel` is the
    /// pre-resolved persona name ("Steward" or "{Domain} team"). Pod B emits
    /// invocations on the coordinator's session so the UI defaults to
    /// "Steward" unless the tool itself encodes a domain in its args.
    static func build(
        invocation: LLMToolInvocation,
        defaultActorLabel: String,
        defaultDomainKey: String?,
        eventID: String?
    ) -> ToolCallSummary {
        guard let toolID = ToolID(rawValue: invocation.toolID) else {
            return ToolCallSummary(
                actorLabel: defaultActorLabel,
                domainKey: defaultDomainKey,
                verb: "ran",
                object: invocation.toolID,
                toolID: invocation.toolID,
                argsSummary: invocation.argsJSON,
                reasoning: nil,
                resultSummary: invocation.resultJSON,
                eventID: eventID,
                isReversible: false,
                supportsShowInToday: false
            )
        }

        let parsedArgs = parseArgs(invocation.argsJSON)
        let domain = stringArg(parsedArgs, "domain") ?? defaultDomainKey
        let actorLabel: String = {
            if let d = stringArg(parsedArgs, "domain"), !d.isEmpty {
                return "\(d.capitalized) team"
            }
            return defaultActorLabel
        }()

        let (verb, object) = verbObject(for: toolID, args: parsedArgs)
        return ToolCallSummary(
            actorLabel: actorLabel,
            domainKey: domain,
            verb: verb,
            object: object,
            toolID: toolID.rawValue,
            argsSummary: argsLine(parsedArgs),
            reasoning: stringArg(parsedArgs, "reasoning"),
            resultSummary: shortenResult(invocation.resultJSON),
            eventID: eventID,
            isReversible: isReversible(toolID),
            supportsShowInToday: showInTodayApplies(toolID)
        )
    }

    // MARK: - Verb/object table (Designer §1.3 verbatim where possible)

    private static func verbObject(
        for toolID: ToolID,
        args: [String: String]
    ) -> (verb: String, object: String) {
        switch toolID {
        case .eventCapture:
            return ("logged", args["kind"] ?? "an event")
        case .eventList, .eventRecentSummary:
            return ("checked", "the event log")
        case .instrumentCreate:
            return ("started tracking", args["name"] ?? "an instrument")
        case .instrumentApplyEvent:
            return ("updated", args["instrument_id"] ?? args["name"] ?? "an instrument")
        case .instrumentUpdateDefinition:
            return ("tuned", args["instrument_id"] ?? "an instrument")
        case .instrumentArchive:
            return ("archived", args["instrument_id"] ?? "an instrument")
        case .instrumentList, .instrumentRead:
            return ("checked", "instruments")
        case .commitmentCreate:
            return ("wrote down", args["title"] ?? "a commitment")
        case .commitmentComplete:
            return ("marked done", args["title"] ?? "a commitment")
        case .commitmentAbandon:
            return ("dropped", args["title"] ?? "a commitment")
        case .commitmentSnooze:
            return ("snoozed", args["title"] ?? "a commitment")
        case .commitmentList:
            return ("checked", "commitments")
        case .memorySave:
            return ("remembered", trimTo(40, args["text"] ?? "something") + "…")
        case .memoryForget:
            return ("let go of", trimTo(40, args["text"] ?? "something") + "…")
        case .memorySearch, .memoryListRecent:
            return ("looked up", "memory")
        case .memoryStrengthen:
            return ("reinforced", args["memory_id"] ?? "a memory")
        case .notificationSchedule:
            let title = args["title"] ?? args["kind"] ?? "a nudge"
            let when = args["fire_at"] ?? args["when"] ?? ""
            return ("scheduled nudge", when.isEmpty ? title : "\(title) at \(when)")
        case .notificationScheduleRecurring:
            return ("scheduled recurring", args["title"] ?? args["kind"] ?? "a nudge")
        case .notificationCancel:
            return ("cancelled nudge", args["title"] ?? args["notification_id"] ?? "a nudge")
        case .notificationListUpcoming:
            return ("checked", "upcoming nudges")
        case .calendarRead:
            return ("checked calendar", "events")
        case .calendarWrite:
            return ("added to calendar", args["title"] ?? "an event")
        case .calendarModify:
            return ("edited event", args["title"] ?? "an event")
        case .calendarDelete:
            return ("removed from calendar", args["title"] ?? "an event")
        case .reminderCreate:
            return ("added reminder", args["title"] ?? "a reminder")
        case .reminderComplete:
            return ("marked reminder done", args["title"] ?? "a reminder")
        case .reminderList:
            return ("checked", "reminders")
        case .csvMirrorEnsureInstrumentFile:
            return ("set up", "spreadsheet file")
        case .csvMirrorSyncNow:
            return ("synced", "to iCloud Drive")
        case .csvMirrorReadOverrides:
            return ("read", "spreadsheet edits")
        case .domainCreate:
            return ("spawned", "\(args["display_name"] ?? args["domain"] ?? "a") team")
        case .domainList:
            return ("checked", "teams")
        case .domainUpdatePrompt:
            return ("updated", "\(args["display_name"] ?? args["domain"] ?? "a") team role")
        case .domainArchive:
            return ("archived", "\(args["display_name"] ?? args["domain"] ?? "a") team")
        case .agentHandoff:
            return ("handed off to", "\(args["domain"] ?? "a") team")
        case .agentCrossConsult:
            return ("asked", "\(args["domain"] ?? "a") team")
        case .mercyModeEngage:
            if let until = args["until_when"] ?? args["until"] {
                return ("engaged", "mercy mode until \(until)")
            }
            return ("engaged", "mercy mode")
        case .pauseEngage:
            if let until = args["until_when"] ?? args["until"] {
                return ("paused", "until \(until)")
            }
            return ("paused", "Steward")
        case .quietHoursSet:
            let start = args["start"] ?? "?"
            let end = args["end"] ?? "?"
            return ("set quiet hours", "\(start)–\(end)")
        case .webSearch:
            return ("searched the web", args["query"] ?? "for something")
        }
        // Note: no `default` — adding a ToolID case is a compile error
        // (§4 hard reject #9).
    }

    /// Reversibility per Designer §1.3 list, constrained by Pod C's
    /// implemented inverses. The full Designer list included tools whose
    /// inverses don't (yet) live in `InverseAction`; rendering Undo for
    /// them would surface qa-1's "Nothing to undo" — instead we only mark
    /// reversible the tools whose audit row carries a real, executable
    /// `InverseAction` and whose `UndoExecutor` handler is implemented.
    private static func isReversible(_ toolID: ToolID) -> Bool {
        switch toolID {
        case .calendarWrite, .calendarModify, .calendarDelete,
             .reminderCreate, .reminderComplete,
             .notificationSchedule, .notificationScheduleRecurring, .notificationCancel,
             .instrumentApplyEvent,
             .domainCreate, .domainArchive,
             .memorySave, .memoryForget:
            return true
        case .calendarRead, .reminderList,
             .eventCapture, .eventList, .eventRecentSummary,
             .instrumentCreate, .instrumentList, .instrumentRead,
             .instrumentUpdateDefinition, .instrumentArchive,
             .commitmentCreate, .commitmentComplete, .commitmentAbandon,
             .commitmentSnooze, .commitmentList,
             .memorySearch, .memoryListRecent, .memoryStrengthen,
             .notificationListUpcoming,
             .csvMirrorEnsureInstrumentFile, .csvMirrorSyncNow, .csvMirrorReadOverrides,
             .domainList, .domainUpdatePrompt,
             .agentHandoff, .agentCrossConsult,
             .mercyModeEngage, .pauseEngage, .quietHoursSet,
             .webSearch:
            return false
        }
    }

    private static func showInTodayApplies(_ toolID: ToolID) -> Bool {
        switch toolID {
        case .instrumentCreate, .instrumentApplyEvent, .instrumentUpdateDefinition,
             .instrumentArchive, .instrumentRead,
             .commitmentCreate, .commitmentComplete:
            return true
        case .eventCapture, .eventList, .eventRecentSummary,
             .instrumentList,
             .commitmentList, .commitmentAbandon, .commitmentSnooze,
             .memorySave, .memorySearch, .memoryForget, .memoryStrengthen, .memoryListRecent,
             .notificationSchedule, .notificationScheduleRecurring, .notificationCancel,
             .notificationListUpcoming,
             .calendarRead, .calendarWrite, .calendarModify, .calendarDelete,
             .reminderCreate, .reminderComplete, .reminderList,
             .csvMirrorEnsureInstrumentFile, .csvMirrorSyncNow, .csvMirrorReadOverrides,
             .domainCreate, .domainList, .domainUpdatePrompt, .domainArchive,
             .agentHandoff, .agentCrossConsult,
             .mercyModeEngage, .pauseEngage, .quietHoursSet, .webSearch:
            return false
        }
    }

    // MARK: - JSON helpers (kept dumb — we don't need full parsing fidelity)

    /// Parses an args JSON into a flat string-valued dict. Non-string scalars
    /// are coerced via `String(describing:)`. Nested objects flatten to their
    /// JSON representation. Failure (malformed JSON, non-object root) yields
    /// an empty dict — the UI still renders, just with generic verb/object.
    private static func parseArgs(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let dict = root as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String { out[k] = s }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
            else if v is NSNull { out[k] = "" }
            else if let data = try? JSONSerialization.data(withJSONObject: v),
                    let s = String(data: data, encoding: .utf8) {
                out[k] = s
            } else {
                out[k] = String(describing: v)
            }
        }
        return out
    }

    private static func stringArg(_ args: [String: String], _ key: String) -> String? {
        guard let v = args[key], !v.isEmpty else { return nil }
        return v
    }

    private static func argsLine(_ args: [String: String]) -> String {
        // Deterministic ordering — sorted keys; reasoning excluded because
        // the UI shows it on its own "Why" line.
        let pairs = args
            .filter { $0.key != "reasoning" }
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(trimTo(60, $0.value))" }
        return pairs.joined(separator: ", ")
    }

    private static func shortenResult(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 200 { return trimmed }
        return String(trimmed.prefix(200)) + "…"
    }

    private static func trimTo(_ n: Int, _ s: String) -> String {
        s.count <= n ? s : String(s.prefix(n))
    }
}
