//
//  EventKitGatewayTests.swift
//  StewardTests
//
//  Tests the permission-revocation propagation logic in EventKitGateway via
//  a scripted EKAuthorizationStatusProvider. We can't unit-test the real
//  EKEventStore (Simulator doesn't surface the iOS permission dialog), but we
//  can verify:
//   - `.notDetermined` ⇒ executeCalendarRead returns .permissionRequired (no
//     EKEventStore.requestAccess fired — addendum §1.9 hybrid deferral).
//   - `.denied` ⇒ executeCalendarRead returns .permissionDenied.
//   - `refreshIfAuthChanged()` re-instantiates the store when scripted status
//     transitions from `.notDetermined` to `.fullAccess` (mocks observed via
//     factory invocation count).
//

import XCTest
import EventKit
@testable import Steward

/// Minimal EKEventStore stand-in. We only need it to be returned by the
/// factory so we can observe re-instantiation; method coverage is irrelevant
/// for the permission-lifecycle path (the gateway short-circuits at gateCheck
/// before reaching the store).
final class StubEventStore: EventStoreProtocol, @unchecked Sendable {

    func requestFullAccessToEvents() async throws -> Bool { true }
    func requestWriteOnlyAccessToEvents() async throws -> Bool { true }
    func requestFullAccessToReminders() async throws -> Bool { true }

    func events(matching predicate: NSPredicate) -> [EKEvent] { [] }
    func predicateForEvents(withStart startDate: Date, end: Date, calendars: [EKCalendar]?) -> NSPredicate {
        NSPredicate(value: true)
    }
    func calendars(for entityType: EKEntityType) -> [EKCalendar] { [] }
    var defaultCalendarForNewEvents: EKCalendar? { nil }
    func defaultCalendarForNewReminders() -> EKCalendar? { nil }
    func calendar(withIdentifier: String) -> EKCalendar? { nil }
    func newEvent() -> EKEvent {
        // Build a detached event — these instances aren't tied to a store
        // when the test isn't exercising save paths.
        return EKEvent(eventStore: EKEventStore())
    }
    func event(withIdentifier: String) -> EKEvent? { nil }
    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {}
    func newReminder() -> EKReminder {
        return EKReminder(eventStore: EKEventStore())
    }
    func reminders(matching predicate: NSPredicate) async throws -> [EKReminder] { [] }
    func predicateForReminders(in calendars: [EKCalendar]?) -> NSPredicate { NSPredicate(value: true) }
    func predicateForIncompleteReminders(
        withDueDateStarting startDate: Date?,
        ending endDate: Date?,
        calendars: [EKCalendar]?
    ) -> NSPredicate { NSPredicate(value: true) }
    func predicateForCompletedReminders(
        withCompletionDateStarting startDate: Date?,
        ending endDate: Date?,
        calendars: [EKCalendar]?
    ) -> NSPredicate { NSPredicate(value: true) }
    func calendarItem(withIdentifier: String) -> EKCalendarItem? { nil }
    func save(_ reminder: EKReminder, commit: Bool) throws {}
    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {}
    func remove(_ reminder: EKReminder, commit: Bool) throws {}
}

/// Scripted status box — tests mutate it, the provider closure reads it.
final class ScriptedAuthStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [EKEntityType: EKAuthorizationStatus] = [:]
    func set(_ status: EKAuthorizationStatus, for entityType: EKEntityType) {
        lock.lock(); defer { lock.unlock() }
        statuses[entityType] = status
    }
    func get(_ entityType: EKEntityType) -> EKAuthorizationStatus {
        lock.lock(); defer { lock.unlock() }
        return statuses[entityType] ?? .notDetermined
    }
}

/// Factory that counts re-instantiations so refreshIfAuthChanged() observation
/// can be asserted.
final class FactoryCounter: @unchecked Sendable {
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

final class EventKitGatewayTests: XCTestCase {

    private func makeGateway() -> (EventKitGateway, ScriptedAuthStatus, FactoryCounter) {
        let scripted = ScriptedAuthStatus()
        let counter = FactoryCounter()
        let factory: @Sendable () -> any EventStoreProtocol = {
            counter.bump()
            return StubEventStore()
        }
        let provider: EKAuthorizationStatusProvider = { entityType in
            scripted.get(entityType)
        }
        let gateway = EventKitGateway(storeFactory: factory, statusProvider: provider)
        return (gateway, scripted, counter)
    }

    func testNotDeterminedReturnsPermissionRequired() async {
        let (gateway, scripted, _) = makeGateway()
        scripted.set(.notDetermined, for: .event)
        let result = await gateway.executeCalendarRead(
            CalendarReadArgs(start: Date(), end: Date().addingTimeInterval(3600))
        )
        switch result {
        case .permissionRequired(let scope):
            XCTAssertEqual(scope, .calendarFullAccess)
        default:
            XCTFail("expected permissionRequired, got \(result)")
        }
    }

    func testDeniedReturnsPermissionDenied() async {
        let (gateway, scripted, _) = makeGateway()
        scripted.set(.denied, for: .event)
        let result = await gateway.executeCalendarRead(
            CalendarReadArgs(start: Date(), end: Date().addingTimeInterval(3600))
        )
        switch result {
        case .permissionDenied(let scope, let hint):
            XCTAssertEqual(scope, .calendarFullAccess)
            XCTAssertFalse(hint.isEmpty)
        default:
            XCTFail("expected permissionDenied, got \(result)")
        }
    }

    func testFullAccessProceeds() async {
        let (gateway, scripted, _) = makeGateway()
        scripted.set(.fullAccess, for: .event)
        let result = await gateway.executeCalendarRead(
            CalendarReadArgs(start: Date(), end: Date().addingTimeInterval(3600))
        )
        switch result {
        case .ok: /* good */ break
        default: XCTFail("expected .ok, got \(result)")
        }
    }

    func testRefreshReinstantiatesStoreOnStatusChange() async {
        let (gateway, scripted, counter) = makeGateway()
        scripted.set(.notDetermined, for: .event)
        scripted.set(.notDetermined, for: .reminder)
        // First touch: status read, but no change since lastKnown is empty.
        await gateway.refreshIfAuthChanged()
        let firstCount = counter.snapshot

        // Flip status — refreshIfAuthChanged should re-instantiate.
        scripted.set(.fullAccess, for: .event)
        await gateway.refreshIfAuthChanged()
        XCTAssertGreaterThan(counter.snapshot, firstCount,
                             "EKEventStore re-instantiation expected on auth change")
    }

    func testRefreshIsNoopWhenStatusUnchanged() async {
        let (gateway, scripted, counter) = makeGateway()
        scripted.set(.fullAccess, for: .event)
        scripted.set(.fullAccess, for: .reminder)
        // Two refreshes with the same status — second should not bump factory.
        await gateway.refreshIfAuthChanged()
        let after1 = counter.snapshot
        await gateway.refreshIfAuthChanged()
        XCTAssertEqual(counter.snapshot, after1, "no re-instantiation when status unchanged")
    }
}
