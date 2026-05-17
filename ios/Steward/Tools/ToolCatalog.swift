//
//  ToolCatalog.swift
//  Steward
//
//  Single entry point Pod B's AgentLoop calls to enumerate the full tool
//  surface. Returns one `LLMTool` per spec §8 entry (minus the EventKit /
//  notifications / CSV mirror / WhisperKit tools owned by Pods D and F —
//  those pods register their own catalogs and merge into this one at
//  AgentLoop construction).
//

import Foundation

enum ToolCatalog {
    /// Full Track-C surface. Pod B merges this with Pod D + Pod F catalogs
    /// when building the coordinator's available-tools list.
    static func allTrackCTools(
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
            // Cross-agent (Pod B registers `AgentHandoffTool` itself with
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
