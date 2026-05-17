//
//  NetworkObserver.swift
//  Steward — Track F
//
//  `NWPathMonitor` wrapper that drives the sync queue worker per spec §13:
//  "Network state observer (NWPathMonitor) drives sync queue worker."
//
//  Single shared actor; subscribers register Sendable callbacks fired when the
//  path transitions to .satisfied (and once on initial start so the worker
//  drains anything queued at launch).
//

import Foundation
import Network

/// Coarse path state mapped from `NWPath.Status` so callers don't need to
/// import Network.
enum NetworkReachability: Sendable, Equatable {
    case unknown
    case satisfied
    case unsatisfied
    case requiresConnection
}

actor NetworkObserver {
    static let shared = NetworkObserver()

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var started: Bool = false

    /// Last observed state. Cached so subscribers can read without waiting on
    /// the next path update.
    private(set) var current: NetworkReachability = .unknown

    /// Subscriber callbacks. Keyed by identifier so callers can unsubscribe.
    private var subscribers: [String: @Sendable (NetworkReachability) async -> Void] = [:]

    init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.rajatscode.steward.network-observer", qos: .utility)
    }

    /// Start the monitor. Idempotent. Safe to call from app bootstrap before
    /// any subscribers are registered — initial state is delivered on the
    /// first path update.
    func start() {
        guard !started else { return }
        started = true
        // We capture nothing from `self` directly — the path-update handler
        // hops into the actor via an unstructured Task.
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let mapped: NetworkReachability
            switch path.status {
            case .satisfied: mapped = .satisfied
            case .unsatisfied: mapped = .unsatisfied
            case .requiresConnection: mapped = .requiresConnection
            @unknown default: mapped = .unknown
            }
            Task { await self.handle(update: mapped) }
        }
        monitor.start(queue: queue)
    }

    /// Stop monitoring. Useful at app shutdown / scene disconnect.
    func stop() {
        guard started else { return }
        monitor.cancel()
        started = false
    }

    /// Register a callback for reachability transitions. The callback fires
    /// once immediately with the current state, then on every change. Returns
    /// a token for `unsubscribe(token:)`.
    @discardableResult
    func subscribe(_ callback: @escaping @Sendable (NetworkReachability) async -> Void) -> String {
        let token = ULID.generate()
        subscribers[token] = callback
        let snapshot = current
        Task { await callback(snapshot) }
        return token
    }

    func unsubscribe(token: String) {
        subscribers.removeValue(forKey: token)
    }

    // MARK: - Private

    private func handle(update: NetworkReachability) async {
        let changed = update != current
        current = update
        guard changed else { return }
        for (_, cb) in subscribers {
            await cb(update)
        }
    }
}

/// App bootstrap helper: wires the observer to the CSV mirror tools so a
/// path-becomes-satisfied transition triggers `syncNow()`. Call from
/// `StewardApp.start()` once.
enum NetworkObserverBootstrap {
    static func wireCSVDrain() async {
        await NetworkObserver.shared.start()
        _ = await NetworkObserver.shared.subscribe { reach in
            if case .satisfied = reach {
                _ = try? await CSVMirrorTools.shared.syncNow()
            }
        }
    }
}
