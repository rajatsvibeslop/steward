//
//  ToolID.swift
//  Steward — Agent/_Stubs/
//
//  DELETE AT MERGE — Pod B owns canonical per addendum §1.8.
//
//  Closed enum = merge conflict if pods add cases piecemeal. To avoid that,
//  this stub declares EVERY tool from spec §8 upfront so Pod C / Pod D / Pod
//  F can reference `ToolID.<case>` without touching the file. Pod B's
//  canonical copy must keep the same case names and rawValues for the swap
//  to be lossless.
//
//  HARD REJECT #9 prevention: string-keyed kind dispatch is forbidden; route
//  through this enum.
//

import Foundation

/// Canonical tool identifiers used across tracks. Source of truth: spec §8.
/// Track B's `ToolGuard` (addendum §1.8) validates by these rawValues.
enum ToolID: String, Codable, CaseIterable, Sendable {
    // MARK: events
    case eventCapture          = "event.capture"
    case eventList             = "event.list"
    case eventRecentSummary    = "event.recent_summary"

    // MARK: instruments
    case instrumentCreate           = "instrument.create"
    case instrumentList             = "instrument.list"
    case instrumentRead             = "instrument.read"
    case instrumentApplyEvent       = "instrument.apply_event"
    case instrumentUpdateDefinition = "instrument.update_definition"
    case instrumentArchive          = "instrument.archive"

    // MARK: commitments
    case commitmentCreate    = "commitment.create"
    case commitmentList      = "commitment.list"
    case commitmentComplete  = "commitment.complete"
    case commitmentAbandon   = "commitment.abandon"
    case commitmentSnooze    = "commitment.snooze"

    // MARK: memory
    case memorySave         = "memory.save"
    case memorySearch       = "memory.search"
    case memoryForget       = "memory.forget"
    case memoryStrengthen   = "memory.strengthen"
    case memoryListRecent   = "memory.list_recent"

    // MARK: notifications (Track D)
    case notificationSchedule          = "notification.schedule"
    case notificationScheduleRecurring = "notification.schedule_recurring"
    case notificationCancel            = "notification.cancel"
    case notificationListUpcoming      = "notification.list_upcoming"

    // MARK: calendar + reminders (Track D)
    case calendarRead      = "calendar.read"
    case calendarWrite     = "calendar.write"
    case calendarModify    = "calendar.modify"
    case calendarDelete    = "calendar.delete"
    case reminderCreate    = "reminder.create"
    case reminderComplete  = "reminder.complete"
    case reminderList      = "reminder.list"

    // MARK: CSV mirror (Track F)
    case csvMirrorEnsureInstrumentFile = "csv_mirror.ensure_instrument_file"
    case csvMirrorSyncNow              = "csv_mirror.sync_now"
    case csvMirrorReadOverrides        = "csv_mirror.read_overrides"

    // MARK: domains
    case domainCreate        = "domain.create"
    case domainList          = "domain.list"
    case domainUpdatePrompt  = "domain.update_prompt"
    case domainArchive       = "domain.archive"

    // MARK: cross-agent (Track B)
    case agentHandoff       = "agent.handoff"
    case agentCrossConsult  = "agent.cross_consult"

    // MARK: web (deferred)
    case webSearch  = "web.search"

    // MARK: settings + safety (Track D consumes via SettingsStore)
    case mercyModeEngage  = "mercy_mode.engage"
    case pauseEngage      = "pause.engage"
    case quietHoursSet    = "quiet_hours.set"
}
