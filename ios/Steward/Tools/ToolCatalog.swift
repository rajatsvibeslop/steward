//
//  ToolCatalog.swift
//  Steward
//
//  Single entry point AgentLoopHost calls to enumerate the leaf tools
//  in `Tools/Catalog/`. Returns one `LLMTool` per spec §8 entry that has
//  no runtime-actor dependency (events, instruments, commitments, memory,
//  domains, agent.cross_consult, settings/safety).
//
//  Tools backed by process-wide actors — calendar, reminders, notifications,
//  HealthKit, CSV mirror — are NOT in this enumeration. AgentLoopHost adds
//  them directly after merging this list.
//

import Foundation

enum ToolCatalog {
    /// Leaf-tool surface (see file header). AgentLoopHost merges this with
    /// the calendar / reminder / notification / HealthKit tools when
    /// building the coordinator's available-tools list.
    static func allCatalogTools(
        provider: DatabaseProvider = .shared,
        settings: SettingsStore = .shared,
        embedder: Embedder = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> [any LLMTool] {
        return [
            // Capture
            EventCaptureTool(provider: provider, now: now),
            EventListTool(provider: provider),
            EventRecentSummaryTool(provider: provider, now: now),
            // Instruments
            InstrumentCreateTool(provider: provider, now: now),
            InstrumentListTool(provider: provider),
            InstrumentReadTool(provider: provider),
            InstrumentApplyEventTool(provider: provider, now: now),
            InstrumentUpdateDefinitionTool(provider: provider, now: now),
            InstrumentArchiveTool(provider: provider, now: now),
            // Commitments
            CommitmentCreateTool(provider: provider, now: now),
            CommitmentListTool(provider: provider),
            CommitmentCompleteTool(provider: provider, now: now),
            CommitmentAbandonTool(provider: provider, now: now),
            CommitmentSnoozeTool(provider: provider, now: now),
            // Memory
            MemorySaveTool(provider: provider, embedder: embedder, now: now),
            MemorySearchTool(provider: provider, embedder: embedder, now: now),
            MemoryForgetTool(provider: provider, now: now),
            MemoryStrengthenTool(provider: provider, now: now),
            MemoryListRecentTool(provider: provider, now: now),
            // Domains
            DomainCreateTool(provider: provider, now: now),
            DomainListTool(provider: provider),
            DomainUpdatePromptTool(provider: provider, now: now),
            DomainArchiveTool(provider: provider, now: now),
            // Cross-agent (AgentLoop registers `AgentHandoffTool` itself with
            // its runtime deps when building the coordinator tool list; we
            // only contribute `cross_consult`, which is a true leaf tool).
            AgentCrossConsultTool(),
            // Settings + safety
            MercyModeEngageTool(provider: provider, settings: settings, now: now),
            PauseEngageTool(provider: provider, settings: settings, now: now),
            QuietHoursSetTool(provider: provider, settings: settings, now: now),
        ]
    }
}
