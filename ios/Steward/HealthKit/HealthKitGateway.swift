//
//  HealthKitGateway.swift
//  Steward — v1.1 HealthKit read-only spike.
//
//  Mirrors `EventKitGateway` (addendum §1.9):
//   - SHARED singleton so the willEnterForeground observer chain registers
//     exactly once;
//   - actor-serialized access — every `health.*` tool routes through this
//     gateway, never calls `HKHealthStore` directly (the EventKit equivalent
//     is HARD REJECT #18);
//   - hybrid deferred-permission lifecycle: NEVER prompts during onboarding,
//     only when the LLM first calls `health.read_quantity`. The gateway
//     returns `.permissionRequired`; the UI intercepts and triggers the
//     inline-grant flow (HARD REJECT #17 + #19);
//   - re-evaluates auth on `UIApplication.willEnterForegroundNotification`
//     since users can revoke Health access from Settings → Health → Steward.
//
//  NOTE on HealthKit's read-privacy quirk: Apple deliberately hides read-
//  denial state from apps (privacy: would let apps fingerprint which Health
//  categories a user has data for). So in production the gateway's
//  `.permissionDenied` branch is unreachable for reads — denied reads
//  surface as empty result sets. We keep the case for symmetry with
//  EventKit and to exercise it from `MockHealthStore` in tests.
//

import Foundation
import HealthKit

#if canImport(UIKit)
import UIKit
#endif

// MARK: - HealthStore abstraction (testable)

/// Slice of `HKHealthStore` the gateway actually uses. Production binds it
/// to a real `HKHealthStore`; `MockHealthStore` in tests scripts each
/// method without touching the real Health database.
protocol HealthStoreProtocol: AnyObject, Sendable {
    /// Triggered by the inline-grant flow. The OS shows the prompt; this
    /// method returns once the user has answered. Must NEVER be called
    /// during onboarding. Mirrors `HKHealthStore.requestAuthorization(toShare:read:)`
    /// — non-optional sets; pass `[]` to skip share/read.
    func requestAuthorization(
        toShare share: Set<HKSampleType>,
        read: Set<HKObjectType>
    ) async throws

    /// Quantity-sample read (used for body mass + step count).
    func readQuantitySamples(
        type: HKQuantityType,
        predicate: NSPredicate?,
        limit: Int
    ) async throws -> [HKQuantitySample]

    /// Category-sample read (used for sleep analysis).
    func readCategorySamples(
        type: HKCategoryType,
        predicate: NSPredicate?,
        limit: Int
    ) async throws -> [HKCategorySample]
}

// MARK: - Live HKHealthStore bridge

extension HKHealthStore: @unchecked Sendable {}
extension HKHealthStore: HealthStoreProtocol {
    func readQuantitySamples(
        type: HKQuantityType,
        predicate: NSPredicate?,
        limit: Int
    ) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKQuantitySample], Error>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            self.execute(query)
        }
    }

    func readCategorySamples(
        type: HKCategoryType,
        predicate: NSPredicate?,
        limit: Int
    ) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKCategorySample], Error>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            self.execute(query)
        }
    }
}

// MARK: - Live auth-status provider

/// Production status provider — calls Apple's async
/// `statusForAuthorizationRequest(toShare:read:)` and maps the result onto
/// `HealthAuthState`. The mapping is intentionally lossy for reads (see
/// the read-privacy quirk in the file header).
func liveHealthAuthStatusProvider(
    store: HKHealthStore = HKHealthStore()
) -> HealthAuthStatusProvider {
    return { scope in
        guard HKHealthStore.isHealthDataAvailable() else {
            return .error("HealthKit is not available on this device")
        }
        let readTypes = scope.readTypes
        guard !readTypes.isEmpty else {
            return .error("Internal: empty read-type set for scope \(scope.rawValue)")
        }
        do {
            let status = try await store.statusForAuthorizationRequest(
                toShare: [],
                read: readTypes
            )
            switch status {
            case .shouldRequest:
                return .notDetermined
            case .unnecessary:
                return .authorized
            case .unknown:
                return .error("HealthKit returned unknown authorization status")
            @unknown default:
                // Future enum cases: treat as error so we never silently
                // proceed without permission. Matches EventKitGateway's
                // posture for @unknown default.
                return .error("HealthKit returned an unrecognized authorization status")
            }
        } catch {
            return .error("HealthKit authorization status error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Gateway actor

actor HealthKitGateway {
    static let shared = HealthKitGateway()

    private var store: any HealthStoreProtocol
    private let storeFactory: @Sendable () -> any HealthStoreProtocol
    private let statusProvider: HealthAuthStatusProvider
    private var lastKnownState: [HealthPermissionScope: HealthAuthState] = [:]
    private var observersRegistered: Bool = false

    init(
        storeFactory: @escaping @Sendable () -> any HealthStoreProtocol = { HKHealthStore() },
        statusProvider: @escaping HealthAuthStatusProvider = liveHealthAuthStatusProvider()
    ) {
        self.storeFactory = storeFactory
        self.statusProvider = statusProvider
        self.store = storeFactory()
        Task { await self.registerObservers() }
    }

    // MARK: - Public surface

    func state(for scope: HealthPermissionScope) async -> HealthAuthState {
        await statusProvider(scope)
    }

    /// Triggered by the UI inline-grant flow ONLY. Must NEVER be called
    /// during onboarding (matches the EventKitGateway `requestAccess`
    /// contract).
    func requestAccess(for scope: HealthPermissionScope) async -> HealthAuthState {
        do {
            try await store.requestAuthorization(
                toShare: [],
                read: scope.readTypes
            )
        } catch {
            // Swallow: the post-call status read is the source of truth.
        }
        let newState = await statusProvider(scope)
        lastKnownState[scope] = newState
        return newState
    }

    /// Called on `UIApplication.willEnterForegroundNotification`. Compares
    /// the current state to last-known and re-instantiates `store` if
    /// anything changed — matches `EventKitGateway.refreshIfAuthChanged()`.
    func refreshIfAuthChanged() async {
        var changed = false
        for scope in HealthPermissionScope.allCases {
            let cur = await statusProvider(scope)
            let prev = lastKnownState[scope]
            if cur != prev {
                changed = true
                lastKnownState[scope] = cur
            }
        }
        if changed {
            self.store = storeFactory()
        }
    }

    // MARK: - Tool entry points

    func readSleepSamples(start: Date, end: Date) async -> HealthToolResult {
        let scope: HealthPermissionScope = .readAll
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return .permissionRequired(scope: scope)
        case .permissionDenied(let s, let h): return .permissionDenied(scope: s, hint: h)
        case .systemError(let s, let h): return .systemError(scope: s, hint: h)
        }
        guard let categoryType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return .systemError(scope: scope, hint: "Sleep analysis category unavailable on this OS")
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: end, options: [.strictStartDate]
        )
        let samples: [HKCategorySample]
        do {
            samples = try await store.readCategorySamples(
                type: categoryType, predicate: predicate, limit: HKObjectQueryNoLimit
            )
        } catch {
            return .systemError(scope: scope, hint: "Sleep read failed: \(error.localizedDescription)")
        }
        let dtos: [HealthSleepSample] = samples.map { s in
            HealthSleepSample(
                startDate: s.startDate,
                endDate: s.endDate,
                sleepState: sleepStateString(rawValue: s.value),
                sourceName: s.sourceRevision.source.name
            )
        }
        let payload = encodeJSON(["samples": dtos]) ?? "{\"samples\":[]}"
        return .ok(payloadJSON: payload)
    }

    func readBodyMassSamples(start: Date, end: Date, unit: HKUnit) async -> HealthToolResult {
        await readQuantitySamples(
            scope: .readAll,
            identifier: .bodyMass,
            unit: unit,
            start: start,
            end: end
        )
    }

    func readStepCountSamples(start: Date, end: Date) async -> HealthToolResult {
        await readQuantitySamples(
            scope: .readAll,
            identifier: .stepCount,
            unit: .count(),
            start: start,
            end: end
        )
    }

    // MARK: - Internal helpers

    private func readQuantitySamples(
        scope: HealthPermissionScope,
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async -> HealthToolResult {
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return .permissionRequired(scope: scope)
        case .permissionDenied(let s, let h): return .permissionDenied(scope: s, hint: h)
        case .systemError(let s, let h): return .systemError(scope: s, hint: h)
        }
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            return .systemError(scope: scope, hint: "Quantity type \(identifier.rawValue) unavailable on this OS")
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: end, options: [.strictStartDate]
        )
        let samples: [HKQuantitySample]
        do {
            samples = try await store.readQuantitySamples(
                type: quantityType, predicate: predicate, limit: HKObjectQueryNoLimit
            )
        } catch {
            return .systemError(scope: scope, hint: "Quantity read failed: \(error.localizedDescription)")
        }
        let unitString = unit.unitString
        let dtos: [HealthQuantitySample] = samples.map { s in
            HealthQuantitySample(
                startDate: s.startDate,
                endDate: s.endDate,
                value: s.quantity.doubleValue(for: unit),
                unit: unitString,
                sourceName: s.sourceRevision.source.name
            )
        }
        let payload = encodeJSON(["samples": dtos]) ?? "{\"samples\":[]}"
        return .ok(payloadJSON: payload)
    }

    /// Gate-check the scope. Returns `.ok` if the call should proceed, else
    /// a typed `HealthToolResult` to short-circuit the tool.
    private func gateCheck(scope: HealthPermissionScope) async -> HealthToolResult {
        let state = await statusProvider(scope)
        lastKnownState[scope] = state
        switch state {
        case .authorized:
            return .ok(payloadJSON: "")
        case .notDetermined:
            return .permissionRequired(scope: scope)
        case .denied:
            return HealthToolResult.denied(scope)
        case .error(let detail):
            return .systemError(scope: scope, hint: detail)
        }
    }

    private func registerObservers() {
        guard !observersRegistered else { return }
        observersRegistered = true

        #if canImport(UIKit)
        let center = NotificationCenter.default
        let willEnterForeground = UIApplication.willEnterForegroundNotification
        Task.detached { [weak self] in
            let stream = center.notifications(named: willEnterForeground)
            for await _ in stream {
                await self?.refreshIfAuthChanged()
            }
        }
        #endif
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Sleep state mapping

/// HKCategoryValueSleepAnalysis raw values → stable string tokens for the
/// wire payload. Strings keep the contract independent of Apple's integer
/// enum values (which Apple may renumber across OS versions for new states).
private func sleepStateString(rawValue: Int) -> String {
    if let value = HKCategoryValueSleepAnalysis(rawValue: rawValue) {
        switch value {
        case .inBed:                return "in_bed"
        case .asleepUnspecified:    return "asleep_unspecified"
        case .awake:                return "awake"
        case .asleepCore:           return "asleep_core"
        case .asleepDeep:           return "asleep_deep"
        case .asleepREM:            return "asleep_rem"
        @unknown default:           return "unknown"
        }
    }
    return "unknown"
}
