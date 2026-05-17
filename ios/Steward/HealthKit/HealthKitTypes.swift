//
//  HealthKitTypes.swift
//  Steward — v1.1 HealthKit read-only spike.
//
//  Mirrors the EventKit tool-result vocabulary (addendum §1.9) so the agent
//  loop, audit log, and UI can treat Health permissions identically to
//  Calendar / Reminder permissions:
//   - `.permissionRequired` is intercepted by the UI (HARD REJECT #19 — never
//     reaches the LLM transcript).
//   - `.permissionDenied` / `.systemError` are LLM-visible structured tool
//     errors so the model picks a sensible recovery path.
//
//  Scope and sample surfaces are narrow on purpose: this spike reads only
//  sleep analysis (HKCategoryType), body mass, and step count. Adding more
//  types means widening `HealthSampleKind` AND `HealthPermissionScope`
//  together so the gate-check stays exhaustive.
//
//  Naming note: the kind enum is `HealthSampleKind` (not `…QuantityKind`)
//  because `.sleep` routes to `HKCategoryType` (sleepAnalysis), not a
//  quantity sample. The tool ID `health.read_quantity` is intentionally NOT
//  renamed — it's wire-visible (LLM prompts, audit log) and changing it
//  would invalidate prior tool-call transcripts. Internal type names are
//  free to be accurate.
//

import Foundation
import HealthKit

// MARK: - Permission scope

/// Logical permission grouping for the gateway. Maps to a concrete set of
/// `HKObjectType` read types when the gateway gate-checks or requests access.
/// One scope per logical surface keeps the wire vocabulary stable even as we
/// extend the underlying type set.
enum HealthPermissionScope: String, Codable, Sendable, Equatable, CaseIterable {
    /// All three read-only types: sleep, body mass, step count. The spike
    /// requests them as a bundle so the user grants once and the inline-grant
    /// flow only ever fires a single OS prompt for Health.
    case readAll

    var readTypes: Set<HKObjectType> {
        switch self {
        case .readAll:
            var types: Set<HKObjectType> = []
            if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
                types.insert(sleep)
            }
            if let mass = HKObjectType.quantityType(forIdentifier: .bodyMass) {
                types.insert(mass)
            }
            if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
                types.insert(steps)
            }
            return types
        }
    }
}

/// The three sample surfaces the LLM may request. String-backed so the
/// `health.read_quantity` tool can route on a stable JSON token without ever
/// switching on a raw `HKQuantityTypeIdentifier` or `HKCategoryTypeIdentifier`.
///
/// `.sleep` routes to `HKCategoryType.sleepAnalysis`; `.bodyMass` and
/// `.stepCount` route to `HKQuantityType` — hence "sample" rather than
/// "quantity" in the name.
enum HealthSampleKind: String, Codable, Sendable, Equatable, CaseIterable {
    case sleep        = "sleep"
    case bodyMass     = "body_mass"
    case stepCount    = "step_count"
}

// MARK: - Live auth state abstraction

/// What the gateway learned about Health authorization for a scope. Live
/// production code computes this via `HKHealthStore.statusForAuthorizationRequest`
/// (Apple's API for "would prompting be needed?"); tests inject a scripted
/// closure so we can drive the gateway through all four states without a
/// real HealthKit store.
///
/// NOTE: Apple deliberately does NOT surface a "user denied read access"
/// state to apps (privacy: would let apps fingerprint which Health categories
/// the user uses). So in production the `.denied` case is unreachable for
/// reads — empty result sets are returned instead. We keep the case so the
/// type stays symmetric with `EKAuthorizationStatus`, exercise it in tests via
/// the mock store, and have a place to surface real denial signals if Apple
/// ever loosens the privacy posture.
enum HealthAuthState: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case error(String)
}

typealias HealthAuthStatusProvider = @Sendable (HealthPermissionScope) async -> HealthAuthState

// MARK: - Tool-result vocabulary

enum HealthToolResult: Sendable {
    case ok(payloadJSON: String)
    case permissionRequired(scope: HealthPermissionScope)
    case permissionDenied(scope: HealthPermissionScope, hint: String)
    case systemError(scope: HealthPermissionScope, hint: String)
}

extension HealthToolResult {
    static func denied(_ scope: HealthPermissionScope) -> HealthToolResult {
        let hint = "Health access is off. Open Settings → Privacy → Health → Steward to grant access."
        return .permissionDenied(scope: scope, hint: hint)
    }
}

// MARK: - Tool argument struct

/// Args for `health.read_quantity`. Mirrors the EventKit-tool args shape:
///   - reasoning REQUIRED (HARD REJECT #11 — audit log demands a reason),
///   - explicit actor not required at the wire level (the dispatcher tags
///     it from the active scope), so unlike mutation tools we don't carry it
///     in args,
///   - Codable with exhaustive keys (Decoder fails closed on unknown keys
///     when the LLM hallucinates a field).
struct HealthReadQuantityArgs: Codable, Sendable, Equatable {
    var type: HealthSampleKind
    var start: Date
    var end: Date
    var reasoning: String
}

// MARK: - DTOs

/// One sleep-analysis sample. `sleepState` is the HKCategoryValueSleepAnalysis
/// raw value name (e.g. "asleepCore"), kept as a string so the wire payload
/// doesn't bind to Apple's enum integers.
struct HealthSleepSample: Codable, Sendable, Equatable {
    var startDate: Date
    var endDate: Date
    var sleepState: String
    var sourceName: String?
}

/// One quantity sample (body mass or step count). `unit` is the unit string
/// (e.g. "kg", "count") so the LLM can format without us guessing.
struct HealthQuantitySample: Codable, Sendable, Equatable {
    var startDate: Date
    var endDate: Date
    var value: Double
    var unit: String
    var sourceName: String?
}

// MARK: - Permission-required signal (UI interception)

/// Thrown by `HealthReadQuantityTool` when the gateway returns
/// `.permissionRequired`. The dispatcher catches it host-side BEFORE the
/// result reaches the LLM, runs the inline-grant flow, and retries once —
/// matching the EventKit `PermissionRequiredSignal` contract verbatim.
struct HealthPermissionRequiredSignal: Error, Sendable, Equatable {
    let scope: HealthPermissionScope
    var pendingToolID: String?
    var pendingArgsJSON: String?

    init(scope: HealthPermissionScope, pendingToolID: String? = nil, pendingArgsJSON: String? = nil) {
        self.scope = scope
        self.pendingToolID = pendingToolID
        self.pendingArgsJSON = pendingArgsJSON
    }
}
