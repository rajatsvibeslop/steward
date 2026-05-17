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

    var body: some Scene {
        WindowGroup {
            RootView()
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
    }
}

/// Track F bootstrap. Resolves the iCloud Drive container (falling back to
/// app-support if unavailable), wires the CSVMirrorWatcher into the tools
/// façade, kicks off the NWPathMonitor that drains the sync queue, and
/// schedules the WhisperKit eager-init off the main actor so the first
/// hold-to-talk tap feels instant.
enum TrackFBootstrap {
    static func run() async {
        // 0. Register stub instrument-kind coders so reconciliation has
        //    something to dispatch on before Track C ships. REMOVE AT MERGE.
        await registerStubCoders()

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
        //    if voice is disabled in settings.
        Task.detached(priority: .utility) {
            await VoiceCaptureService.shared.initializeIfNeeded()
        }
    }

    /// REMOVE AT MERGE — Pod C provides canonical InstrumentCSVCoder
    /// registrations from their `InstrumentKind` registry boot path. This
    /// helper is paired with `_Stubs/StubRunningAccumulatorCoder.swift` and
    /// `_Stubs/ULIDFactoryStub.swift`; delete this method, its call site
    /// above, and both stub files when Pod C lands.
    static func registerStubCoders() async {
        await InstrumentCSVCoderRegistry.shared.register(
            kindID: StubRunningAccumulatorCoder.kindID,
            coder: StubRunningAccumulatorCoder.make()
        )
    }
}
