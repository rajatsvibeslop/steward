//
//  BGTaskCoordinator.swift
//  Steward
//
//  Registers BGAppRefreshTask + BGProcessingTask handlers, schedules the next
//  app-refresh, and on every foreground tick proactively tops up the next
//  7 days of notifications (researcher landmine: BGTasks are unreliable in the
//  first install week — never rely on them for correctness).
//
//  Handler responsibilities:
//   - drain sync queue (CSVMirrorTools owns the actual drain; this just kicks the
//     refresh actor when it lands)
//   - call NotificationScheduler.topUpHorizon(daysAhead: 7)
//   - reschedule the next BGAppRefreshTask before returning
//

import Foundation
import BackgroundTasks

enum BGIdentifier {
    static let refresh = "com.rajatscode.steward.refresh"
    static let processing = "com.rajatscode.steward.processing"
}

actor BGTaskCoordinator {
    static let shared = BGTaskCoordinator()

    private let scheduler: NotificationScheduler
    /// CSVMirrorTools drains this; we keep an optional reference so the
    /// drain can be wired in without touching this file.
    private var syncDrainer: (@Sendable () async -> Void)?

    init(scheduler: NotificationScheduler = .shared) {
        self.scheduler = scheduler
    }

    func setSyncDrainer(_ drainer: @escaping @Sendable () async -> Void) {
        self.syncDrainer = drainer
    }

    // MARK: - Registration

    /// Call ONCE in `application(_:didFinishLaunchingWithOptions:)` (or the
    /// SwiftUI App init equivalent). Registering twice raises an exception
    /// from BGTaskScheduler — the `@MainActor`-isolated bootstrap is the
    /// single chokepoint.
    @MainActor
    static func registerHandlers() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BGIdentifier.refresh,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task {
                await BGTaskCoordinator.shared.handleAppRefresh(task: refreshTask)
            }
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BGIdentifier.processing,
            using: nil
        ) { task in
            guard let proc = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task {
                await BGTaskCoordinator.shared.handleProcessing(task: proc)
            }
        }
    }

    // MARK: - Scheduling

    /// Submit the next BGAppRefreshTask. Best-effort — iOS may decline.
    func scheduleNextRefresh(after seconds: TimeInterval = 60 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: BGIdentifier.refresh)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BGTaskScheduler returns errors for already-submitted tasks
            // (.tooManyPendingTaskRequests = 3) which is fine to swallow;
            // any real failure surfaces here for the next foreground tick.
        }
    }

    /// Foreground tick driver. Call from `.task` on RootView OR from
    /// `UIApplication.didBecomeActiveNotification`. Idempotent.
    func foregroundTick() async {
        await scheduler.topUpHorizon(daysAhead: 7)
        scheduleNextRefresh()
        if let drainer = syncDrainer {
            await drainer()
        }
    }

    // MARK: - Handlers

    private func handleAppRefresh(task: BGAppRefreshTask) async {
        // BGAppRefreshTask gets ~30s. We do the cheapest correctness-critical
        // work first (notification top-up) so even a tight budget lands a
        // working week of brief notifications.
        let expirationFlag = ExpirationFlag()
        task.expirationHandler = { expirationFlag.markExpired() }

        await scheduler.topUpHorizon(daysAhead: 7)
        if expirationFlag.isExpired {
            scheduleNextRefresh()
            task.setTaskCompleted(success: false)
            return
        }
        if let drainer = syncDrainer {
            await drainer()
        }
        // Persist memory decay (addendum §1.5). MemoryRetriever already
        // applies the lazy form at retrieval time so v1 ranking is correct
        // without this — the pass exists to bump `strength_at_last_update`
        // for indexed sort queries and to soft-delete rows that have fallen
        // below the 0.05 threshold. Errors are swallowed inside the helper:
        // a DB hiccup must not abort the surrounding BGTask refresh cycle.
        await runMemoryDecayPass()
        scheduleNextRefresh()
        task.setTaskCompleted(success: !expirationFlag.isExpired)
    }

    private func handleProcessing(task: BGProcessingTask) async {
        // BGProcessingTask gets a few minutes when on charger / Wi-Fi. We
        // use it for the same drain + top-up + memory decay persistence.
        let expirationFlag = ExpirationFlag()
        task.expirationHandler = { expirationFlag.markExpired() }

        await scheduler.topUpHorizon(daysAhead: 14)
        if let drainer = syncDrainer {
            await drainer()
        }
        await runMemoryDecayPass()
        task.setTaskCompleted(success: !expirationFlag.isExpired)
    }

    // MARK: - Decay

    /// Resolve the shared writer and run a `MemoryDecayJob` persistence pass.
    /// Internal seam — exposed (rather than inlined) so tests can drive the
    /// same code path without instantiating a `BGAppRefreshTask` (a system
    /// class that can't be constructed from test code). The helper returns
    /// the run outcome (or `nil` if the DB was unavailable) for diagnostics;
    /// callers in the handler path discard it intentionally.
    @discardableResult
    func runMemoryDecayPass(now: Date = Date()) async -> MemoryDecayJob.Outcome? {
        guard let queue = try? await DatabaseProvider.shared.database() else {
            // Intentional swallow: the DB-open path surfaces its own typed
            // error to first-paint UI via AppBootstrap.Phase.failed. The
            // periodic decay pass is best-effort and must not pile on.
            return nil
        }
        return await MemoryDecayJob.runPersistencePass(on: queue, now: now)
    }
}

/// Tiny mailbox-style flag so the expiration handler (which runs on whatever
/// queue iOS chose) can communicate back into our async handler without
/// resorting to `@unchecked Sendable` on the BGTask object itself.
private final class ExpirationFlag: @unchecked Sendable {
    private var expired = false
    private let lock = NSLock()
    func markExpired() {
        lock.lock(); defer { lock.unlock() }
        expired = true
    }
    var isExpired: Bool {
        lock.lock(); defer { lock.unlock() }
        return expired
    }
}
