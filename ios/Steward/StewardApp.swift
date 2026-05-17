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

            // Track F bootstrap: CSV mirror + network-driven sync + voice eager init.
            // All best-effort — voice failing (no model) or iCloud unavailable
            // must not block the app from opening.
            await TrackFBootstrap.run()

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

/// Track F bootstrap. Resolves the iCloud Drive container (falling back to
/// app-support if unavailable), wires the CSVMirrorWatcher into the tools
/// façade, kicks off the NWPathMonitor that drains the sync queue, and
/// schedules the WhisperKit eager-init off the main actor so the first
/// hold-to-talk tap feels instant.
enum TrackFBootstrap {
    static func run() async {
        // 0. Wire each registered InstrumentKind into the CSV mirror via the
        //    InstrumentCSVCoder adapter. Pod C's InstrumentRegistry.bootstrapAll()
        //    runs above us in AppBootstrap.start (line 55), so by this point
        //    all 7 kinds are registered with the typed registry and we just
        //    need to plug their renderCSV/parseCSVOverride into our CSV
        //    coder registry.
        await registerKindCoders()

        // 1. Load settings to honor csv_mirror_enabled / icloud_drive_folder.
        let settings: Settings
        do {
            settings = try await SettingsStore.shared.load()
        } catch {
            return // bootstrap is best-effort
        }

        // 2. Pick a CSV mirror root. Prefer the iCloud ubiquity container; if
        //    iCloud Drive isn't enabled, fall back to Application Support so
        //    the user still gets a working in-app surface.
        if settings.csvMirrorEnabled {
            let root: CSVMirrorRoot
            if FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.rajatscode.steward") != nil {
                root = .ubiquityContainer(
                    identifier: "iCloud.com.rajatscode.steward",
                    subfolder: settings.icloudDriveFolder
                )
            } else {
                root = .applicationSupport(subfolder: settings.icloudDriveFolder)
            }
            if let paths = try? CSVMirrorPaths.resolve(root) {
                let watcher = CSVMirrorWatcher(paths: paths)
                try? await watcher.startWatching()
                await CSVMirrorTools.shared.configure(watcher: watcher)
            }
        }

        // 3. Network observer drains the sync queue when path becomes satisfied.
        await NetworkObserverBootstrap.wireCSVDrain()

        // 4. Voice eager init. Detached so the model load (potentially
        //    multi-hundred MB) doesn't slow first paint. The service no-ops
        //    if voice is disabled in settings. Once init returns (success or
        //    fail), install the adapter into the registry so ChatView's
        //    mic button reflects the real service state, and post the
        //    readiness-changed notification so any already-mounted ChatView
        //    re-reads `availability`.
        Task.detached(priority: .utility) {
            await VoiceCaptureService.shared.initializeIfNeeded()
            await MainActor.run {
                VoiceCaptureRegistry.current = VoiceCaptureAdapter()
                NotificationCenter.default.post(
                    name: .voiceCaptureReadinessChanged,
                    object: nil
                )
            }
        }
    }

    /// Register one `InstrumentCSVCoder` per Pod C kind. Adding a kind is
    /// one line here + one line in `InstrumentRegistry.bootstrapAll()`.
    /// Both lists are kept in sync — if Pod C adds an 8th kind, this method
    /// gets one more line and that's it. No string-keyed dispatch anywhere
    /// (hard reject #9 still holds; the registry is the single dispatch site).
    static func registerKindCoders() async {
        let registry = InstrumentCSVCoderRegistry.shared
        await registry.register(kindID: RunningAccumulator.id,
                                coder: InstrumentCSVCoder(kind: RunningAccumulator.self))
        await registry.register(kindID: BoundedBudget.id,
                                coder: InstrumentCSVCoder(kind: BoundedBudget.self))
        await registry.register(kindID: RollingAverage.id,
                                coder: InstrumentCSVCoder(kind: RollingAverage.self))
        await registry.register(kindID: CountdownCommitment.id,
                                coder: InstrumentCSVCoder(kind: CountdownCommitment.self))
        await registry.register(kindID: WeeklyEvidenceLog.id,
                                coder: InstrumentCSVCoder(kind: WeeklyEvidenceLog.self))
        await registry.register(kindID: Checklist.id,
                                coder: InstrumentCSVCoder(kind: Checklist.self))
        await registry.register(kindID: BoundedWindow.id,
                                coder: InstrumentCSVCoder(kind: BoundedWindow.self))
    }
}
