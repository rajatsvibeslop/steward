//
//  AgentLoopHost.swift
//  Steward
//
//  Process-wide container that builds the `AgentLoop` (Agent/AgentLoop.swift)
//  exactly once and caches it for the lifetime of the app. This file does NOT
//  redeclare the loop — it only wires it up. `AgentLoop` itself takes
//  factory + registry + resolver via its init; there is no `AgentLoop.shared`.
//
//  At first call, `AgentLoopHost.shared.ready()`:
//   - resolves the best `LLMSessionFactory` via `LLMResolver.resolve()`
//     (Foundation Models when available, Mock otherwise),
//   - builds a `MapToolRegistry` populated with the tool-catalog (from
//     `ToolCatalog.allCatalogTools()`) PLUS the calendar / reminder /
//     notification / HealthKit tools (their gateways are process-wide actors,
//     not catalog leaf tools),
//   - constructs `AgentLoop` with a `DBDomainAgentResolver` so handoffs pick
//     up live domain rows.
//
//  The chat UI awaits `ready()` before its first send so the registry is
//  populated. Subsequent `ready()` calls return the cached host.
//

import Foundation

/// One process-wide host so the UI never re-builds the registry. The actor
/// serializes the "set up everything" phase exactly once.
actor AgentLoopHost {
    static let shared = AgentLoopHost()

    private enum State {
        case unset
        case building(Task<Ready, Error>)
        case ready(Ready)
    }

    struct Ready: Sendable {
        let loop: AgentLoop
        let backendKind: LLMBackendKind
        /// Registry handle so the chat UI can re-fire a single tool call
        /// after an inline permission grant (addendum §1.9 — "auto-retries
        /// the original tool call once"). Exposed here, not on AgentLoop,
        /// because the retry path does NOT consume a turn budget hop and
        /// does NOT go through the LLM at all.
        let toolRegistry: any ToolRegistry
    }

    private var state: State = .unset

    private init() {}

    /// Resolves the loop, building it on first call. Multiple concurrent
    /// callers wait on a single Task so the registry only gets populated
    /// once.
    func ready() async throws -> Ready {
        switch state {
        case .ready(let r):
            return r
        case .building(let t):
            return try await t.value
        case .unset:
            let task = Task<Ready, Error> { try await Self.build() }
            state = .building(task)
            do {
                let r = try await task.value
                state = .ready(r)
                return r
            } catch {
                state = .unset
                throw error
            }
        }
    }

    /// Settings-tab "About" surface reads this directly so the FM-status row
    /// re-renders without a chat round-trip.
    func currentBackendKind() async -> LLMBackendKind? {
        if case .ready(let r) = state { return r.backendKind }
        return nil
    }

    /// Re-fire the exact tool invocation the model attempted before the
    /// permission signal was thrown. Returns the tool's wire JSON on
    /// success (which the UI can summarise into a tool-call card), throws
    /// the same signal again if the user actually denied access at the OS
    /// sheet, or any other tool error otherwise. The chat UI is responsible
    /// for the "retry once" contract — this method itself does not loop.
    func retryToolCall(toolID: String, argsJSON: String) async throws -> String {
        let ready = try await ready()
        guard let typed = ToolID(rawValue: toolID),
              let tool = await ready.toolRegistry.tool(for: typed) else {
            throw LLMSessionError.toolNotFound(toolID: toolID)
        }
        return try await tool.invoke(argsJSON: argsJSON)
    }

    // MARK: - Construction

    private static func build() async throws -> Ready {
        let resolution = await LLMResolver.resolve()
        let registry = MapToolRegistry()

        // Leaf tools from the catalog (events, instruments, commitments,
        // memory, domains, settings, agent.cross_consult).
        for tool in ToolCatalog.allCatalogTools() {
            if let id = ToolID(rawValue: tool.id) {
                await registry.register(tool, as: id)
            }
        }

        // Calendar / reminder / notification tools — backed by process-wide
        // actors (EventKitGateway, NotificationScheduler), so they aren't in
        // the catalog enumeration. They're added here, once, at app launch.
        //
        // We deliberately do NOT register the real `AgentHandoffTool` here.
        // That tool needs per-turn dependencies (the shared TurnBudget) and
        // is installed by `AgentLoop` itself each turn.
        let calendarRead = CalendarReadTool()
        let calendarWrite = CalendarWriteTool()
        let calendarModify = CalendarModifyTool()
        let calendarDelete = CalendarDeleteTool()
        let reminderCreate = ReminderCreateTool()
        let reminderComplete = ReminderCompleteTool()
        let reminderList = ReminderListTool()
        await registry.register(calendarRead, as: .calendarRead)
        await registry.register(calendarWrite, as: .calendarWrite)
        await registry.register(calendarModify, as: .calendarModify)
        await registry.register(calendarDelete, as: .calendarDelete)
        await registry.register(reminderCreate, as: .reminderCreate)
        await registry.register(reminderComplete, as: .reminderComplete)
        await registry.register(reminderList, as: .reminderList)

        let notifSchedule = NotificationScheduleTool()
        let notifScheduleRecurring = NotificationScheduleRecurringTool()
        let notifCancel = NotificationCancelTool()
        let notifList = NotificationListUpcomingTool()
        await registry.register(notifSchedule, as: .notificationSchedule)
        await registry.register(notifScheduleRecurring, as: .notificationScheduleRecurring)
        await registry.register(notifCancel, as: .notificationCancel)
        await registry.register(notifList, as: .notificationListUpcoming)

        // HealthKit read-only (v1.1). HKHealthStore lives on the gateway
        // actor; this tool dispatches through it the same way calendar tools
        // dispatch through EventKitGateway.
        let healthRead = HealthReadQuantityTool()
        await registry.register(healthRead, as: .healthReadQuantity)

        let resolver = DBDomainAgentResolver()
        let temperature: Double
        do {
            let settings = try await SettingsStore.shared.load()
            temperature = settings.defaultAgentTemperature
        } catch {
            // Settings failure must not block the agent loop coming up. Fall
            // back to the spec default — the app seeds 0.7. The user can edit
            // it from Settings once the DB recovers.
            temperature = 0.7
        }

        let loop = AgentLoop(
            factory: resolution.factory,
            registry: registry,
            resolver: resolver,
            temperature: temperature
        )
        return Ready(loop: loop, backendKind: resolution.kind, toolRegistry: registry)
    }
}
