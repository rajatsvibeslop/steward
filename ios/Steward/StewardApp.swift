//
//  StewardApp.swift
//  Steward
//
//  app entry point. Bootstraps the database on launch so the GRDB
//  migrator runs before any view requests data. The workbook cleanup
//  removed the InstrumentRegistry + InstrumentCSVCoder path that v1
//  bootstrapped here; the iCloud-availability classifier still runs
//  so Settings can show honest copy.
//

import SwiftUI
import UserNotifications

@main
struct StewardApp: App {
    @StateObject private var bootstrap = AppBootstrap()

    init() {
        // BGTaskScheduler.register MUST be called before
        // application(_:didFinishLaunchingWithOptions:) returns. SwiftUI's
        // App.init runs at that point, so we register here. Registering
        // twice raises an Objective-C exception — keep this the single site.
        BGTaskCoordinator.registerHandlers()
        // Install the tap-to-act router (spec §10 #4). Without this, taps
        // on wind-down nudges / morning briefs cold-launch the app to the
        // chat root and the stamped action_context_json is dropped — same
        // as opening Steward from Springboard.
        UNUserNotificationCenter.current().delegate = NotificationActionRouter.shared
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
        do {
            _ = try await DatabaseProvider.shared.database()

            // iCloud availability classifier so Settings can show honest
            // copy for the deprecated "csv mirror" toggle. Voice eager
            // init scheduled below.
            await BackgroundServicesBootstrap.run()

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
        // One-shot memory-decay persistence pass on launch. BGTask refreshes
        // are unreliable in the first install week (researcher landmine), so
        // we also run on every cold start — detached + utility priority so
        // it doesn't compete with first paint. Idempotent: the inner SQL
        // skips rows whose `last_strength_update_at` already equals `now`.
        Task.detached(priority: .utility) {
            await BGTaskCoordinator.shared.runMemoryDecayPass()
        }
    }
}

/// Pruned bootstrap. The v1 build wired CSVMirrorWatcher +
/// InstrumentCSVCoderRegistry here; both are gone with the workbook
/// rebrand. We still classify iCloud availability so the Settings UI
/// can show honest copy for the legacy "csv mirror" toggle, and we
/// eager-init voice so the first hold-to-talk tap is responsive.
enum BackgroundServicesBootstrap {
    static func run() async {
        // Load settings to classify iCloud availability.
        let settings: Settings
        do {
            settings = try await SettingsStore.shared.load()
        } catch {
            return // bootstrap is best-effort
        }

        let containerID = "iCloud.com.rajatscode.outkeep"
        let availability = CSVMirrorAvailabilityClassifier.classify(
            mirrorEnabled: settings.csvMirrorEnabled,
            folderName: settings.icloudDriveFolder,
            ubiquityContainerAvailable: {
                FileManager.default.url(forUbiquityContainerIdentifier: containerID) != nil
            }
        )
        await MainActor.run {
            CSVMirrorAvailabilityRegistry.publish(availability)
        }

        // Voice eager init. Detached so the model load (potentially
        // multi-hundred MB) doesn't slow first paint. The service no-ops
        // if voice is disabled in settings. Once init returns (success or
        // fail), install the adapter into the registry so ChatView's
        // mic button reflects the real service state, and post the
        // readiness-changed notification so any already-mounted ChatView
        // re-reads `availability`.
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
}
