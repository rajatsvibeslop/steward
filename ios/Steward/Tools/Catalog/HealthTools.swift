//
//  HealthTools.swift
//  Steward — v1.1 HealthKit read-only spike.
//
//  `health.read_quantity(type, start, end, reasoning)` — single tool routing
//  to the appropriate gateway method based on the `type` discriminator. The
//  pattern mirrors the EventKit tool surface (`CalendarTools.swift`):
//   - dispatches through `HealthKitGateway` (never instantiates `HKHealthStore`
//     directly),
//   - returns the LLM-safe JSON payload via `wireOrThrow(...)`,
//   - hides `.permissionRequired` from the LLM by throwing
//     `HealthPermissionRequiredSignal` — the dispatcher catches it host-side
//     and runs the inline-grant flow.
//
//  No audit-log row: reads are not mutations and addendum §11 only audits
//  agent-driven changes. If we ever add write-back this file gets the same
//  `recordAgentAction` block the calendar/reminder tools have.
//

import Foundation
import HealthKit

actor HealthReadQuantityTool: LLMTool {
    let id = ToolID.healthReadQuantity.rawValue
    let description = "Read sleep, body mass, or step count samples from Apple Health between start and end."
    let jsonSchemaForArgs = """
    {"type":"object","properties":{"type":{"type":"string","enum":["sleep","body_mass","step_count"]},"start":{"type":"string","format":"date-time"},"end":{"type":"string","format":"date-time"},"reasoning":{"type":"string"}},"required":["type","start","end","reasoning"]}
    """

    private let gateway: HealthKitGateway
    private let bodyMassUnit: HKUnit

    init(
        gateway: HealthKitGateway = .shared,
        bodyMassUnit: HKUnit = .gramUnit(with: .kilo)
    ) {
        self.gateway = gateway
        self.bodyMassUnit = bodyMassUnit
    }

    func invoke(argsJSON: String) async throws -> String {
        let args: HealthReadQuantityArgs = try ToolJSON.decode(HealthReadQuantityArgs.self, from: argsJSON)
        let result: HealthToolResult
        switch args.type {
        case .sleep:
            result = await gateway.readSleepSamples(start: args.start, end: args.end)
        case .bodyMass:
            result = await gateway.readBodyMassSamples(
                start: args.start, end: args.end, unit: bodyMassUnit
            )
        case .stepCount:
            result = await gateway.readStepCountSamples(start: args.start, end: args.end)
        }
        return try wireOrThrowHealth(result)
    }
}

// MARK: - Wire formatting

/// Converts a `HealthToolResult` into the LLM-visible wire string, or throws
/// `HealthPermissionRequiredSignal` when the result is `.permissionRequired`
/// so the host-side dispatcher can intercept (matches
/// `wireOrThrow(_:)` in `CalendarTools.swift`).
private func wireOrThrowHealth(_ result: HealthToolResult) throws -> String {
    switch result {
    case .ok(let json):
        return json
    case .permissionRequired(let scope):
        throw HealthPermissionRequiredSignal(scope: scope)
    case .permissionDenied(let scope, let hint):
        return try encodeStatus("permission_denied", scope: scope, hint: hint)
    case .systemError(let scope, let hint):
        return try encodeStatus("system_error", scope: scope, hint: hint)
    }
}

private func encodeStatus(_ status: String, scope: HealthPermissionScope, hint: String) throws -> String {
    let body: [String: String] = [
        "status": status,
        "scope": scope.rawValue,
        "hint": hint
    ]
    return try ToolJSON.encode(body)
}
