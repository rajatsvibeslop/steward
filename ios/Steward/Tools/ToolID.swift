//
//  ToolId.swift
//  Steward
//
//  Addendum §1.8: typed identifier for every tool the agent can call. The
//  enum is the only place tool Ids are spelled out; the catalog's `register`
//  path takes a `ToolId` (not a String), so adding a tool requires adding
//  a case here first.
//

import Foundation

enum ToolId: String, Codable, CaseIterable, Sendable {
    // Capture
    case eventCapture          = "event.capture"
    case eventList             = "event.list"
    case eventRecentSummary    = "event.recent_summary"

    // Instruments
    case instrumentCreate      = "instrument.create"
    case instrumentList        = "instrument.list"
    case instrumentRead        = "instrument.read"
    case instrumentApplyEvent  = "instrument.apply_event"
    case instrumentUpdateDefinition = "instrument.update_definition"
    case instrumentArchive     = "instrument.archive"

    // Commitments
    case commitmentCreate      = "commitment.create"
    case commitmentList        = "commitment.list"
    case commitmentComplete    = "commitment.complete"
    case commitmentAbandon     = "commitment.abandon"
    case commitmentSnooze      = "commitment.snooze"

    // Memory
    case memorySave            = "memory.save"
    case memorySearch          = "memory.search"
    case memoryForget          = "memory.forget"
    case memoryStrengthen      = "memory.strengthen"
    case memoryListRecent      = "memory.list_recent"

    // Domain management
    case domainCreate          = "domain.create"
    case domainList            = "domain.list"
    case domainUpdatePrompt    = "domain.update_prompt"
    case domainArchive         = "domain.archive"

    // Cross-agent (signatures here; Pod B implements bodies)
    case agentHandoff          = "agent.handoff"
    case agentCrossConsult     = "agent.cross_consult"

    // Settings + safety
    case mercyModeEngage       = "mercy_mode.engage"
    case pauseEngage           = "pause.engage"
    case quietHoursSet         = "quiet_hours.set"
}
