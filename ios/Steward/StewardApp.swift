//
//  StewardApp.swift
//  Steward
//
//  Track A scaffold: app entry point. Bootstraps the database on launch
//  so the GRDB migrator runs before any view requests data.
//

import SwiftUI

@main
struct StewardApp: App {
    @StateObject private var bootstrap = AppBootstrap()

    init() {
        // BGTaskScheduler.register MUST be called before
        // application(_:didFinishLaunchingWithOptions:) returns. SwiftUI's
        // App.init runs at that point, so we register here. Registering
        // twice raises an Objective-C exception — keep this the single site.
        BGTaskCoordinator.registerHandlers()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(bootstrap)
                .task {
                    await bootstrap.start()
                }
        }
    }
}

/// Owns the one-time application bootstrap work — currently just opening the
/// database. Other tracks will graft their bootstrap onto this object
/// (Foundation Models availability check, notification permission, EventKit
/// access, BGTaskScheduler registration, etc.).
@MainActor
final class AppBootstrap: ObservableObject {
    enum Phase: Equatable {
        case idle
        case opening
        case ready
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle

    func start() async {
        guard phase == .idle else { return }
        phase = .opening
        // Register all instrument kinds before any agent / view code can
        // dispatch an instrument event. Addendum §1.2 says this happens at
        // @main; the bootstrap object is the @main proxy.
        InstrumentRegistry.bootstrapAll()
        do {
            _ = try await DatabaseProvider.shared.database()
            phase = .ready
        } catch {
            phase = .failed(message: String(describing: error))
        }
        // Whether the DB came up or not, kick the foreground tick so the
        // notification scheduler tops up its horizon. The scheduler doesn't
        // require the DB to function — it reads settings via SettingsStore
        // which surfaces a typed error if the DB is sick.
        await BGTaskCoordinator.shared.foregroundTick()
        // Warm the agent loop singleton so the first chat send doesn't
        // pay the registry-build latency. Fire-and-forget — UI gates on
        // its own `try await AgentLoopHost.shared.ready()` before sending.
        Task.detached {
            _ = try? await AgentLoopHost.shared.ready()
        }
    }
}
