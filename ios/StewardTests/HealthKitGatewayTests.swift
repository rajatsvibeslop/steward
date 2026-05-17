//
//  HealthKitGatewayTests.swift
//  StewardTests — v1.1 HealthKit read-only spike.
//
//  Mirrors EventKitGatewayTests: scripted auth-status provider drives the
//  gateway through all four states (notDetermined / authorized / denied /
//  error). `MockHealthStore` lets us assert that:
//   - `.notDetermined` ⇒ `.permissionRequired` (no `requestAuthorization`
//     fired — addendum §1.9 hybrid deferral),
//   - `.denied`       ⇒ `.permissionDenied`,
//   - `.authorized`   ⇒ `.ok(samples)` with the scripted samples,
//   - read failure   ⇒ `.systemError`,
//   - `refreshIfAuthChanged()` re-instantiates the store on state change,
//   - `HealthReadQuantityArgs` is Codable round-trip,
//   - `HealthReadQuantityTool` produces the exact `ToolJSON` shape the LLM
//     expects.
//

import XCTest
import HealthKit
@testable import Steward

// MARK: - MockHealthStore

/// Scriptable stand-in for `HKHealthStore`. Tests can pre-load the sample
/// arrays returned per `HKQuantityTypeIdentifier` / `HKCategoryTypeIdentifier`
/// and optionally script the read path to throw.
final class MockHealthStore: HealthStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _quantitySamples: [HKQuantityTypeIdentifier: [HKQuantitySample]] = [:]
    private var _categorySamples: [HKCategoryTypeIdentifier: [HKCategorySample]] = [:]
    private var _readError: Error?
    private(set) var requestAuthorizationCallCount: Int = 0
    private(set) var quantityReadCallCount: Int = 0
    private(set) var categoryReadCallCount: Int = 0

    func setQuantitySamples(_ samples: [HKQuantitySample], for id: HKQuantityTypeIdentifier) {
        lock.lock(); defer { lock.unlock() }
        _quantitySamples[id] = samples
    }
    func setCategorySamples(_ samples: [HKCategorySample], for id: HKCategoryTypeIdentifier) {
        lock.lock(); defer { lock.unlock() }
        _categorySamples[id] = samples
    }
    func setReadError(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        _readError = error
    }

    func requestAuthorization(
        toShare share: Set<HKSampleType>,
        read: Set<HKObjectType>
    ) async throws {
        lock.lock(); defer { lock.unlock() }
        requestAuthorizationCallCount += 1
    }

    func readQuantitySamples(
        type: HKQuantityType,
        predicate: NSPredicate?,
        limit: Int
    ) async throws -> [HKQuantitySample] {
        lock.lock()
        quantityReadCallCount += 1
        let err = _readError
        let id = HKQuantityTypeIdentifier(rawValue: type.identifier)
        let samples = _quantitySamples[id] ?? []
        lock.unlock()
        if let err = err { throw err }
        return samples
    }

    func readCategorySamples(
        type: HKCategoryType,
        predicate: NSPredicate?,
        limit: Int
    ) async throws -> [HKCategorySample] {
        lock.lock()
        categoryReadCallCount += 1
        let err = _readError
        let id = HKCategoryTypeIdentifier(rawValue: type.identifier)
        let samples = _categorySamples[id] ?? []
        lock.unlock()
        if let err = err { throw err }
        return samples
    }
}

// MARK: - Scripted auth state

final class ScriptedHealthAuthState: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [HealthPermissionScope: HealthAuthState] = [:]
    func set(_ state: HealthAuthState, for scope: HealthPermissionScope) {
        lock.lock(); defer { lock.unlock() }
        states[scope] = state
    }
    func get(_ scope: HealthPermissionScope) -> HealthAuthState {
        lock.lock(); defer { lock.unlock() }
        return states[scope] ?? .notDetermined
    }
}

final class HealthFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count: Int = 0
    func bump() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
    var snapshot: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

// MARK: - Tests

final class HealthKitGatewayTests: XCTestCase {

    /// Returns gateway + the (single) mock store + scripted state + factory
    /// counter. Most tests only need the gateway and the scripted state, but
    /// we expose the mock and counter so individual tests can assert call
    /// counts and re-instantiation behavior.
    private func makeGateway() -> (HealthKitGateway, MockHealthStore, ScriptedHealthAuthState, HealthFactoryCounter) {
        let scripted = ScriptedHealthAuthState()
        let counter = HealthFactoryCounter()
        // We share one mock instance so tests can preload samples on it and
        // then assert calls. The factory bumps the counter every time the
        // gateway asks for a fresh store; in production that's "auth changed
        // and we need to re-read the HK DB."
        let mock = MockHealthStore()
        let factory: @Sendable () -> any HealthStoreProtocol = {
            counter.bump()
            return mock
        }
        let provider: HealthAuthStatusProvider = { scope in
            scripted.get(scope)
        }
        let gateway = HealthKitGateway(storeFactory: factory, statusProvider: provider)
        return (gateway, mock, scripted, counter)
    }

    // MARK: gateway gateCheck mapping

    func testNotDeterminedReturnsPermissionRequired() async {
        let (gateway, _, scripted, _) = makeGateway()
        scripted.set(.notDetermined, for: .readAll)
        let result = await gateway.readStepCountSamples(
            start: Date(),
            end: Date().addingTimeInterval(3600)
        )
        switch result {
        case .permissionRequired(let scope):
            XCTAssertEqual(scope, .readAll)
        default:
            XCTFail("expected permissionRequired, got \(result)")
        }
    }

    func testDeniedReturnsPermissionDenied() async {
        let (gateway, _, scripted, _) = makeGateway()
        scripted.set(.denied, for: .readAll)
        let result = await gateway.readStepCountSamples(
            start: Date(),
            end: Date().addingTimeInterval(3600)
        )
        switch result {
        case .permissionDenied(let scope, let hint):
            XCTAssertEqual(scope, .readAll)
            XCTAssertFalse(hint.isEmpty)
        default:
            XCTFail("expected permissionDenied, got \(result)")
        }
    }

    func testAuthorizedReturnsSamples() async throws {
        let (gateway, mock, scripted, _) = makeGateway()
        scripted.set(.authorized, for: .readAll)

        let now = Date()
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return XCTFail("stepCount HKQuantityType unavailable")
        }
        let q1 = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: .count(), doubleValue: 1234),
            start: now.addingTimeInterval(-300),
            end: now
        )
        mock.setQuantitySamples([q1], for: .stepCount)

        let result = await gateway.readStepCountSamples(
            start: now.addingTimeInterval(-3600), end: now
        )
        guard case .ok(let payload) = result else {
            return XCTFail("expected .ok, got \(result)")
        }
        // The wire payload is sortedKeys JSON; parse it back rather than
        // string-match so the assertion survives DTO reorderings.
        struct Wrapper: Codable { let samples: [HealthQuantitySample] }
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let parsed = try dec.decode(Wrapper.self, from: data)
        XCTAssertEqual(parsed.samples.count, 1)
        XCTAssertEqual(parsed.samples[0].value, 1234, accuracy: 0.0001)
        XCTAssertEqual(parsed.samples[0].unit, "count")
        XCTAssertEqual(mock.quantityReadCallCount, 1)
    }

    func testSystemErrorOnReadFailure() async {
        let (gateway, mock, scripted, _) = makeGateway()
        scripted.set(.authorized, for: .readAll)
        struct Boom: Error {}
        mock.setReadError(Boom())
        let result = await gateway.readStepCountSamples(
            start: Date().addingTimeInterval(-3600), end: Date()
        )
        switch result {
        case .systemError(let scope, let hint):
            XCTAssertEqual(scope, .readAll)
            XCTAssertFalse(hint.isEmpty)
        default:
            XCTFail("expected systemError, got \(result)")
        }
    }

    func testErrorAuthStateReturnsSystemError() async {
        let (gateway, _, scripted, _) = makeGateway()
        scripted.set(.error("HealthKit unavailable"), for: .readAll)
        let result = await gateway.readBodyMassSamples(
            start: Date().addingTimeInterval(-3600),
            end: Date(),
            unit: .gramUnit(with: .kilo)
        )
        switch result {
        case .systemError(let scope, let hint):
            XCTAssertEqual(scope, .readAll)
            XCTAssertTrue(hint.contains("unavailable"))
        default:
            XCTFail("expected systemError, got \(result)")
        }
    }

    func testRefreshReinstantiatesStoreOnStateChange() async {
        let (gateway, _, scripted, counter) = makeGateway()
        scripted.set(.notDetermined, for: .readAll)
        await gateway.refreshIfAuthChanged()
        let firstCount = counter.snapshot
        scripted.set(.authorized, for: .readAll)
        await gateway.refreshIfAuthChanged()
        XCTAssertGreaterThan(
            counter.snapshot, firstCount,
            "HKHealthStore re-instantiation expected on auth change"
        )
    }

    func testRefreshNoopWhenStateUnchanged() async {
        let (gateway, _, scripted, counter) = makeGateway()
        scripted.set(.authorized, for: .readAll)
        await gateway.refreshIfAuthChanged()
        let after1 = counter.snapshot
        await gateway.refreshIfAuthChanged()
        XCTAssertEqual(
            counter.snapshot, after1,
            "no re-instantiation expected when state unchanged"
        )
    }

    func testGateCheckDoesNotInvokeRequestAuthorization() async {
        // Hybrid-deferral guarantee (HARD REJECT #17): the gateway must
        // surface `.permissionRequired` without ever calling
        // `requestAuthorization` on the store. UI runs the inline grant.
        let (gateway, mock, scripted, _) = makeGateway()
        scripted.set(.notDetermined, for: .readAll)
        _ = await gateway.readSleepSamples(start: Date(), end: Date())
        _ = await gateway.readStepCountSamples(start: Date(), end: Date())
        _ = await gateway.readBodyMassSamples(start: Date(), end: Date(), unit: .gramUnit(with: .kilo))
        XCTAssertEqual(mock.requestAuthorizationCallCount, 0)
    }

    func testSleepSamplesParseAllStates() async throws {
        let (gateway, mock, scripted, _) = makeGateway()
        scripted.set(.authorized, for: .readAll)

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return XCTFail("sleepAnalysis HKCategoryType unavailable")
        }
        let now = Date()
        let samples: [HKCategorySample] = [
            HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                start: now.addingTimeInterval(-3600),
                end: now.addingTimeInterval(-1800)
            ),
            HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                start: now.addingTimeInterval(-1800),
                end: now
            ),
        ]
        mock.setCategorySamples(samples, for: .sleepAnalysis)

        let result = await gateway.readSleepSamples(
            start: now.addingTimeInterval(-7200), end: now
        )
        guard case .ok(let payload) = result else {
            return XCTFail("expected .ok, got \(result)")
        }
        struct Wrapper: Codable { let samples: [HealthSleepSample] }
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let parsed = try dec.decode(Wrapper.self, from: data)
        XCTAssertEqual(parsed.samples.count, 2)
        let states = parsed.samples.map(\.sleepState).sorted()
        XCTAssertEqual(states, ["asleep_core", "asleep_rem"])
    }

    // MARK: HealthReadQuantityArgs Codable round-trip

    func testHealthReadQuantityArgsRoundTrip() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_003_600)
        let original = HealthReadQuantityArgs(
            type: .bodyMass,
            start: start,
            end: end,
            reasoning: "User asked for last hour's weight readings."
        )
        let json = try ToolJSON.encode(original)
        let decoded = try ToolJSON.decode(HealthReadQuantityArgs.self, from: json)
        XCTAssertEqual(decoded, original)
    }

    func testHealthReadQuantityArgsRejectsUnknownType() {
        let bad = """
        {"type":"hr_variability","start":"2026-05-17T00:00:00Z","end":"2026-05-17T01:00:00Z","reasoning":"x"}
        """
        XCTAssertThrowsError(try ToolJSON.decode(HealthReadQuantityArgs.self, from: bad))
    }

    // MARK: HealthReadQuantityTool integration

    func testHealthReadQuantityToolEmitsOkPayload() async throws {
        let scripted = ScriptedHealthAuthState()
        scripted.set(.authorized, for: .readAll)
        let mock = MockHealthStore()
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return XCTFail("stepCount HKQuantityType unavailable")
        }
        let now = Date()
        let q1 = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: .count(), doubleValue: 5000),
            start: now.addingTimeInterval(-3600),
            end: now
        )
        mock.setQuantitySamples([q1], for: .stepCount)

        let gateway = HealthKitGateway(
            storeFactory: { mock },
            statusProvider: { scope in scripted.get(scope) }
        )
        let tool = HealthReadQuantityTool(gateway: gateway)
        let args = HealthReadQuantityArgs(
            type: .stepCount,
            start: now.addingTimeInterval(-7200),
            end: now,
            reasoning: "Brief: today's step count"
        )
        let argsJSON = try ToolJSON.encode(args)
        let resultJSON = try await tool.invoke(argsJSON: argsJSON)
        XCTAssertTrue(resultJSON.contains("\"samples\""))
        XCTAssertTrue(resultJSON.contains("5000"))
    }

    func testHealthReadQuantityToolThrowsPermissionRequiredSignal() async throws {
        let scripted = ScriptedHealthAuthState()
        scripted.set(.notDetermined, for: .readAll)
        let mock = MockHealthStore()
        let gateway = HealthKitGateway(
            storeFactory: { mock },
            statusProvider: { scope in scripted.get(scope) }
        )
        let tool = HealthReadQuantityTool(gateway: gateway)
        let args = HealthReadQuantityArgs(
            type: .sleep,
            start: Date().addingTimeInterval(-7200),
            end: Date(),
            reasoning: "Brief: last night's sleep"
        )
        let argsJSON = try ToolJSON.encode(args)
        do {
            _ = try await tool.invoke(argsJSON: argsJSON)
            XCTFail("expected HealthPermissionRequiredSignal")
        } catch let signal as HealthPermissionRequiredSignal {
            XCTAssertEqual(signal.scope, .readAll)
        } catch {
            XCTFail("expected HealthPermissionRequiredSignal, got \(error)")
        }
    }

    func testHealthReadQuantityToolReturnsStructuredErrorOnDenied() async throws {
        let scripted = ScriptedHealthAuthState()
        scripted.set(.denied, for: .readAll)
        let mock = MockHealthStore()
        let gateway = HealthKitGateway(
            storeFactory: { mock },
            statusProvider: { scope in scripted.get(scope) }
        )
        let tool = HealthReadQuantityTool(gateway: gateway)
        let args = HealthReadQuantityArgs(
            type: .bodyMass,
            start: Date().addingTimeInterval(-7200),
            end: Date(),
            reasoning: "Weekly weight check"
        )
        let argsJSON = try ToolJSON.encode(args)
        let resultJSON = try await tool.invoke(argsJSON: argsJSON)
        XCTAssertTrue(resultJSON.contains("permission_denied"))
        XCTAssertTrue(resultJSON.contains("readAll"))
    }
}
