//
//  AgentLoopSingleton.swift
//  Steward — Track E wiring layer (NOT a canonical-surface stub).
//
//  ARCH NOTE (vetted): this file glues Pod B's canonical `AgentLoop` actor
//  (Agent/AgentLoop.swift) to live process-wide state — it does NOT
//  redeclare or duplicate Pod B's surface. Pod B exposes `public actor
//  AgentLoop` with a custom init taking factory + registry + resolver;
//  there is no `AgentLoop.shared` in Pod B's canonical. `AgentLoopHost.shared`
//  is the resolved-once container so the UI doesn't rebuild the tool
//  registry on every chat send.
//
//  Process-wide AgentLoop assembled at app launch:
//   - resolves the best `LLMSessionFactory` via `LLMResolver.resolve()`,
//   - builds a `MapToolRegistry` populated with every Track C tool from
//     `ToolCatalog.allTrackCTools()` PLUS Track D's calendar / notification /
//     reminder tools (which require their own actors and aren't in the
//     Track C catalog),
//   - constructs `AgentLoop` with a `DBDomainAgentResolver` so hand-offs
//     pick up live domain rows.
//
//  The Chat UI awaits `AgentLoopHost.shared.ready()` so it never sends a
//  message before the registry is populated. Resolution happens once per
//  process; subsequent `ready()` calls return the cached host immediately.
//

import Foundation

/// One process-wide host so the UI never re-builds the registry. The actor
/// serializes the "set up everything" phase exactly once.
public actor AgentLoopHost {
    public static let shared = AgentLoopHost()

    private enum State {
        case unset
        case building(Task<Ready, Error>)
        case ready(Ready)
    }

    public struct Ready: Sendable {
        public let loop: AgentLoop
        public let backendKind: LLMBackendKind
    }

    private var state: State = .unset

    private init() {}

    /// Resolves the loop, building it on first call. Multiple concurrent
    /// callers wait on a single Task so the registry only gets populated
    /// once.
    public func ready() async throws -> Ready {
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
    public func currentBackendKind() async -> LLMBackendKind? {
        if case .ready(let r) = state { return r.backendKind }
        return nil
    }

    // MARK: - Construction

    private static func build() async throws -> Ready {
        let resolution = await LLMResolver.resolve()
        let registry = MapToolRegistry()

        // Track C tools — Pod C's catalog.
        for tool in ToolCatalog.allTrackCTools() {
            if let id = ToolID(rawValue: tool.id) {
                await registry.register(tool, as: id)
            }
        }

        // Track D tools — calendar/reminder/notification. These are actors
        // and not in Pod C's catalog (different ownership), so we add them
        // explicitly here. The two `AgentHandoffTool` instances differ:
        // Pod C's catalog includes a signature-only placeholder; Pod B's
        // AgentLoop installs the real budget-consuming one per-turn. We
        // do NOT register the real handoff tool here — it's per-turn.
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

        let resolver = DBDomainAgentResolver()
        let temperature: Double
        do {
            let settings = try await SettingsStore.shared.load()
            temperature = settings.defaultAgentTemperature
        } catch {
            // Settings failure must not block the agent loop coming up. Fall
            // back to the spec default — Pod A seeds 0.7. The user can edit
            // it from Settings once the DB recovers.
            temperature = 0.7
        }

        let loop = AgentLoop(
            factory: resolution.factory,
            registry: registry,
            resolver: resolver,
            temperature: temperature
        )
        return Ready(loop: loop, backendKind: resolution.kind)
    }
}
