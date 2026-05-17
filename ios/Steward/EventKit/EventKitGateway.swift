//
//  EventKitGateway.swift
//  Steward
//
//  Implementation-addendum §1.9 — actor-serialized EventKit access with the
//  hybrid deferred-permission lifecycle.
//
//  Key behaviors:
//  - SHARED singleton (`shared`) so the willEnterForeground / EKEventStoreChanged
//    observer chain only registers once.
//  - All calendar.* / reminder.* tools route through this actor — direct
//    EKEventStore.requestAccess elsewhere is HARD REJECT #18.
//  - Uses iOS 17+ `requestFullAccessToEvents` / `requestWriteOnlyAccessToEvents`
//    + EKAuthorizationStatus.fullAccess / .writeOnly. Deprecated `.authorized`
//    is HARD REJECT #14.
//  - On `.notDetermined`, returns `.permissionRequired` WITHOUT prompting.
//    UI intercepts and triggers the inline-grant flow. HARD REJECT #17.
//  - Permission revocation: observes `UIApplication.willEnterForegroundNotification`
//    and `EKEventStoreChanged`, re-instantiates EKEventStore on auth change.
//

import Foundation
import EventKit

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Authorization status abstraction (testable)

/// Returns the current `EKAuthorizationStatus` for an entity type. Production
/// uses `EKEventStore.authorizationStatus(for:)`; tests inject a closure that
/// returns scripted statuses for revocation-propagation tests.
typealias EKAuthorizationStatusProvider = @Sendable (EKEntityType) -> EKAuthorizationStatus

func liveAuthorizationStatusProvider() -> EKAuthorizationStatusProvider {
    return { entityType in
        EKEventStore.authorizationStatus(for: entityType)
    }
}

// MARK: - EventStore abstraction (testable)

/// Slice of EKEventStore that the gateway actually uses. Lets tests inject a
/// fake without touching the real EventKit DB.
protocol EventStoreProtocol: AnyObject, Sendable {
    func requestFullAccessToEvents() async throws -> Bool
    func requestWriteOnlyAccessToEvents() async throws -> Bool
    func requestFullAccessToReminders() async throws -> Bool

    /// Calendar window query.
    func events(matching predicate: NSPredicate) -> [EKEvent]
    func predicateForEvents(withStart startDate: Date, end: Date, calendars: [EKCalendar]?) -> NSPredicate
    func calendars(for entityType: EKEntityType) -> [EKCalendar]
    var defaultCalendarForNewEvents: EKCalendar? { get }
    func defaultCalendarForNewReminders() -> EKCalendar?
    func calendar(withIdentifier: String) -> EKCalendar?

    /// Event mutation.
    func newEvent() -> EKEvent
    func event(withIdentifier: String) -> EKEvent?
    func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws

    /// Reminder mutation.
    func newReminder() -> EKReminder
    func reminders(matching predicate: NSPredicate) async throws -> [EKReminder]
    func predicateForReminders(in calendars: [EKCalendar]?) -> NSPredicate
    func predicateForIncompleteReminders(
        withDueDateStarting startDate: Date?,
        ending endDate: Date?,
        calendars: [EKCalendar]?
    ) -> NSPredicate
    func predicateForCompletedReminders(
        withCompletionDateStarting startDate: Date?,
        ending endDate: Date?,
        calendars: [EKCalendar]?
    ) -> NSPredicate
    func calendarItem(withIdentifier: String) -> EKCalendarItem?
    func save(_ reminder: EKReminder, commit: Bool) throws

    func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws
    func remove(_ reminder: EKReminder, commit: Bool) throws
}

/// Bridge so production code keeps using `EKEventStore` directly.
extension EKEventStore: @unchecked Sendable {}
extension EKEventStore: EventStoreProtocol {
    func newEvent() -> EKEvent { EKEvent(eventStore: self) }
    func newReminder() -> EKReminder { EKReminder(eventStore: self) }
    func reminders(matching predicate: NSPredicate) async throws -> [EKReminder] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[EKReminder], Error>) in
            self.fetchReminders(matching: predicate) { reminders in
                cont.resume(returning: reminders ?? [])
            }
        }
    }
}

// MARK: - The actor

actor EventKitGateway {
    static let shared = EventKitGateway()

    private var store: any EventStoreProtocol
    private let storeFactory: @Sendable () -> any EventStoreProtocol
    private let statusProvider: EKAuthorizationStatusProvider
    private var lastKnownStatus: [EKEntityType: EKAuthorizationStatus] = [:]

    /// Observer tokens kept alive so the actor doesn't have to retain them
    /// out-of-band. We register them inside a detached `MainActor` Task at
    /// init (observers are added on whatever queue; we just forward).
    private var observersRegistered: Bool = false

    init(
        storeFactory: @escaping @Sendable () -> any EventStoreProtocol = { EKEventStore() },
        statusProvider: @escaping EKAuthorizationStatusProvider = liveAuthorizationStatusProvider()
    ) {
        self.storeFactory = storeFactory
        self.statusProvider = statusProvider
        self.store = storeFactory()
        Task { await self.registerObservers() }
    }

    // MARK: - Public surface

    func status(for scope: EKPermissionScope) -> EKAuthorizationStatus {
        statusProvider(scope.entityType)
    }

    /// Triggered by the UI inline-grant flow ONLY. Must NEVER be called during
    /// onboarding — that's HARD REJECT #17.
    func requestAccess(for scope: EKPermissionScope) async -> EKAuthorizationStatus {
        do {
            switch scope {
            case .calendarFullAccess:
                _ = try await store.requestFullAccessToEvents()
            case .calendarWriteOnly:
                _ = try await store.requestWriteOnlyAccessToEvents()
            case .remindersFullAccess, .remindersWriteOnly:
                // iOS 17+ exposes `requestFullAccessToReminders`; the
                // write-only Reminders variant landed in iOS 26 SDK only
                // (Xcode 26 toolchain). Track D builds on Xcode 16.3 / iOS
                // 18.4, so both write-only and full-access scopes map to
                // `requestFullAccessToReminders` until the toolchain bump.
                // The mapping is upward-compatible: a user who granted
                // full-access can satisfy a write-only request the same
                // way iOS does internally.
                _ = try await store.requestFullAccessToReminders()
            }
        } catch {
            // Swallow — final status is what we return.
        }
        let newStatus = statusProvider(scope.entityType)
        lastKnownStatus[scope.entityType] = newStatus
        return newStatus
    }

    /// Called by AppDelegate / NotificationCenter observers on foreground
    /// transitions. Compares current status to last-known and re-instantiates
    /// `store` if anything changed.
    func refreshIfAuthChanged() async {
        var changed = false
        for entityType: EKEntityType in [.event, .reminder] {
            let cur = statusProvider(entityType)
            let prev = lastKnownStatus[entityType]
            if cur != prev {
                changed = true
                lastKnownStatus[entityType] = cur
            }
        }
        if changed {
            // EKEventStore caches permission internally; the documented
            // workaround for revocation-while-alive is to re-instantiate.
            self.store = storeFactory()
        }
    }

    // MARK: - Tool entry points

    func executeCalendarRead(_ args: CalendarReadArgs) async -> CalendarToolResult {
        let scope: EKPermissionScope = .calendarFullAccess
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return .permissionRequired(scope: scope)
        case .permissionDenied(let s, let h): return .permissionDenied(scope: s, hint: h)
        case .systemError(let s, let h): return .systemError(scope: s, hint: h)
        }

        let candidateCalendars: [EKCalendar]?
        if let name = args.calendarName {
            candidateCalendars = store.calendars(for: .event).filter { $0.title == name }
        } else {
            candidateCalendars = nil
        }
        let predicate = store.predicateForEvents(
            withStart: args.start,
            end: args.end,
            calendars: candidateCalendars
        )
        let events = store.events(matching: predicate)

        let dtos = events.map { event -> [String: AnyEncodable] in
            [
                "ek_event_id": AnyEncodable(event.eventIdentifier ?? ""),
                "title": AnyEncodable(event.title ?? ""),
                "start_date": AnyEncodable(event.startDate ?? Date()),
                "end_date": AnyEncodable(event.endDate ?? Date()),
                "calendar_name": AnyEncodable(event.calendar?.title ?? ""),
                "calendar_identifier": AnyEncodable(event.calendar?.calendarIdentifier ?? ""),
                "is_all_day": AnyEncodable(event.isAllDay),
                "notes": AnyEncodable(event.notes ?? "")
            ]
        }
        let payload = ["events": dtos]
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(payload)
            return .ok(payloadJSON: String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            return .ok(payloadJSON: "{\"events\":[]}")
        }
    }

    func executeCalendarWrite(_ args: CalendarWriteArgs) async -> (CalendarToolResult, CalendarEventPayload?) {
        let scope: EKPermissionScope = .calendarFullAccess
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return (.permissionRequired(scope: scope), nil)
        case .permissionDenied(let s, let h): return (.permissionDenied(scope: s, hint: h), nil)
        case .systemError(let s, let h): return (.systemError(scope: s, hint: h), nil)
        }

        let event = store.newEvent()
        event.title = args.title
        event.startDate = args.startDate
        event.endDate = args.endDate
        event.notes = args.notes
        event.location = args.location
        event.isAllDay = args.isAllDay ?? false
        if let name = args.calendarName,
           let cal = store.calendars(for: .event).first(where: { $0.title == name })
        {
            event.calendar = cal
        } else if let def = store.defaultCalendarForNewEvents {
            event.calendar = def
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return (.systemError(scope: scope, hint: "Calendar save failed: \(error.localizedDescription)"), nil)
        }

        let payload = CalendarEventPayload(
            title: event.title ?? args.title,
            startDate: event.startDate ?? args.startDate,
            endDate: event.endDate ?? args.endDate,
            notes: event.notes,
            calendarIdentifier: event.calendar?.calendarIdentifier,
            calendarName: event.calendar?.title,
            isAllDay: event.isAllDay,
            location: event.location,
            ekEventID: event.eventIdentifier
        )
        let dto: [String: AnyEncodable] = [
            "ek_event_id": AnyEncodable(event.eventIdentifier ?? ""),
            "title": AnyEncodable(event.title ?? args.title),
            "start_date": AnyEncodable(event.startDate ?? args.startDate),
            "end_date": AnyEncodable(event.endDate ?? args.endDate),
            "calendar_name": AnyEncodable(event.calendar?.title ?? "")
        ]
        let json = encodeJSON(dto) ?? "{}"
        return (.ok(payloadJSON: json), payload)
    }

    /// Returns (result, pre-modification payload). Caller stores the payload
    /// in the InverseAction so undo can re-write the event to its previous
    /// state.
    func executeCalendarModify(_ args: CalendarModifyArgs) async -> (CalendarToolResult, CalendarEventPayload?) {
        let scope: EKPermissionScope = .calendarFullAccess
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return (.permissionRequired(scope: scope), nil)
        case .permissionDenied(let s, let h): return (.permissionDenied(scope: s, hint: h), nil)
        case .systemError(let s, let h): return (.systemError(scope: s, hint: h), nil)
        }

        guard let event = store.event(withIdentifier: args.ekEventID) else {
            return (.ok(payloadJSON: "{\"error\":\"not_found\"}"), nil)
        }
        // Capture pre-modification state before mutating in place.
        let pre = CalendarEventPayload(
            title: event.title ?? "",
            startDate: event.startDate ?? Date(),
            endDate: event.endDate ?? Date(),
            notes: event.notes,
            calendarIdentifier: event.calendar?.calendarIdentifier,
            calendarName: event.calendar?.title,
            isAllDay: event.isAllDay,
            location: event.location,
            ekEventID: event.eventIdentifier
        )

        if let title = args.patch.title { event.title = title }
        if let start = args.patch.startDate { event.startDate = start }
        if let end = args.patch.endDate { event.endDate = end }
        if let notes = args.patch.notes { event.notes = notes }
        if let location = args.patch.location { event.location = location }
        if let isAllDay = args.patch.isAllDay { event.isAllDay = isAllDay }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return (.systemError(scope: scope, hint: "Calendar save failed: \(error.localizedDescription)"), nil)
        }
        let dto: [String: AnyEncodable] = [
            "ek_event_id": AnyEncodable(event.eventIdentifier ?? args.ekEventID),
            "title": AnyEncodable(event.title ?? "")
        ]
        let json = encodeJSON(dto) ?? "{}"
        return (.ok(payloadJSON: json), pre)
    }

    func executeCalendarDelete(_ args: CalendarDeleteArgs) async -> (CalendarToolResult, CalendarEventPayload?) {
        let scope: EKPermissionScope = .calendarFullAccess
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return (.permissionRequired(scope: scope), nil)
        case .permissionDenied(let s, let h): return (.permissionDenied(scope: s, hint: h), nil)
        case .systemError(let s, let h): return (.systemError(scope: s, hint: h), nil)
        }
        guard let event = store.event(withIdentifier: args.ekEventID) else {
            return (.ok(payloadJSON: "{\"deleted\":false,\"reason\":\"not_found\"}"), nil)
        }
        // Capture the full event payload BEFORE deletion so undo can recreate.
        let snapshot = CalendarEventPayload(
            title: event.title ?? "",
            startDate: event.startDate ?? Date(),
            endDate: event.endDate ?? Date(),
            notes: event.notes,
            calendarIdentifier: event.calendar?.calendarIdentifier,
            calendarName: event.calendar?.title,
            isAllDay: event.isAllDay,
            location: event.location,
            ekEventID: event.eventIdentifier
        )
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            return (.systemError(scope: scope, hint: "Calendar delete failed: \(error.localizedDescription)"), nil)
        }
        return (.ok(payloadJSON: "{\"deleted\":true}"), snapshot)
    }

    func executeReminderCreate(_ args: ReminderCreateArgs) async -> (CalendarToolResult, ReminderPayload?) {
        let scope: EKPermissionScope = .remindersFullAccess
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return (.permissionRequired(scope: scope), nil)
        case .permissionDenied(let s, let h): return (.permissionDenied(scope: s, hint: h), nil)
        case .systemError(let s, let h): return (.systemError(scope: s, hint: h), nil)
        }

        let reminder = store.newReminder()
        reminder.title = args.title
        reminder.notes = args.notes
        if let due = args.dueDate {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .autoupdatingCurrent
            reminder.dueDateComponents = cal.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
        }
        if let listName = args.listName,
           let list = store.calendars(for: .reminder).first(where: { $0.title == listName })
        {
            reminder.calendar = list
        } else if let def = store.defaultCalendarForNewReminders() {
            reminder.calendar = def
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            return (.systemError(scope: scope, hint: "Reminder save failed: \(error.localizedDescription)"), nil)
        }
        let payload = ReminderPayload(
            title: reminder.title,
            dueDate: args.dueDate,
            notes: reminder.notes,
            listIdentifier: reminder.calendar?.calendarIdentifier,
            listName: reminder.calendar?.title,
            ekReminderID: reminder.calendarItemIdentifier
        )
        let dto: [String: AnyEncodable] = [
            "ek_reminder_id": AnyEncodable(reminder.calendarItemIdentifier),
            "title": AnyEncodable(reminder.title ?? args.title),
            "list_name": AnyEncodable(reminder.calendar?.title ?? "")
        ]
        let json = encodeJSON(dto) ?? "{}"
        return (.ok(payloadJSON: json), payload)
    }

    func executeReminderComplete(_ args: ReminderCompleteArgs) async -> CalendarToolResult {
        let scope: EKPermissionScope = .remindersFullAccess
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return .permissionRequired(scope: scope)
        case .permissionDenied(let s, let h): return .permissionDenied(scope: s, hint: h)
        case .systemError(let s, let h): return .systemError(scope: s, hint: h)
        }
        guard let item = store.calendarItem(withIdentifier: args.ekReminderID) as? EKReminder else {
            return .ok(payloadJSON: "{\"completed\":false,\"reason\":\"not_found\"}")
        }
        item.isCompleted = true
        do {
            try store.save(item, commit: true)
        } catch {
            return .systemError(scope: scope, hint: "Reminder save failed: \(error.localizedDescription)")
        }
        return .ok(payloadJSON: "{\"completed\":true}")
    }

    /// Reopen a completed reminder (sets `isCompleted = false`). Used by the
    /// undo path for `reminder.complete`. Public so `UndoExecutor` can reach
    /// it without re-implementing the EventKit call there (which would be
    /// HARD REJECT #18 territory).
    func executeReminderReopen(ekReminderID: String) async -> CalendarToolResult {
        let scope: EKPermissionScope = .remindersFullAccess
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return .permissionRequired(scope: scope)
        case .permissionDenied(let s, let h): return .permissionDenied(scope: s, hint: h)
        case .systemError(let s, let h): return .systemError(scope: s, hint: h)
        }
        guard let item = store.calendarItem(withIdentifier: ekReminderID) as? EKReminder else {
            return .ok(payloadJSON: "{\"reopened\":false,\"reason\":\"not_found\"}")
        }
        item.isCompleted = false
        do {
            try store.save(item, commit: true)
        } catch {
            return .systemError(scope: scope, hint: "Reminder save failed: \(error.localizedDescription)")
        }
        return .ok(payloadJSON: "{\"reopened\":true}")
    }

    /// Delete a reminder. Used by the undo path for `reminder.create`.
    func executeReminderDelete(ekReminderID: String) async -> CalendarToolResult {
        let scope: EKPermissionScope = .remindersFullAccess
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return .permissionRequired(scope: scope)
        case .permissionDenied(let s, let h): return .permissionDenied(scope: s, hint: h)
        case .systemError(let s, let h): return .systemError(scope: s, hint: h)
        }
        guard let item = store.calendarItem(withIdentifier: ekReminderID) as? EKReminder else {
            return .ok(payloadJSON: "{\"deleted\":false,\"reason\":\"not_found\"}")
        }
        do {
            try store.remove(item, commit: true)
        } catch {
            return .systemError(scope: scope, hint: "Reminder remove failed: \(error.localizedDescription)")
        }
        return .ok(payloadJSON: "{\"deleted\":true}")
    }

    func executeReminderList(_ args: ReminderListArgs) async -> CalendarToolResult {
        let scope: EKPermissionScope = .remindersFullAccess
        switch await gateCheck(scope: scope) {
        case .ok: break
        case .permissionRequired: return .permissionRequired(scope: scope)
        case .permissionDenied(let s, let h): return .permissionDenied(scope: s, hint: h)
        case .systemError(let s, let h): return .systemError(scope: s, hint: h)
        }
        let calendars: [EKCalendar]?
        if let listName = args.listName {
            calendars = store.calendars(for: .reminder).filter { $0.title == listName }
        } else {
            calendars = nil
        }
        let pred: NSPredicate
        if args.completed == true {
            pred = store.predicateForCompletedReminders(
                withCompletionDateStarting: nil, ending: nil, calendars: calendars
            )
        } else {
            pred = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars
            )
        }
        let reminders: [EKReminder]
        do {
            reminders = try await store.reminders(matching: pred)
        } catch {
            return .ok(payloadJSON: "{\"reminders\":[]}")
        }
        let dtos = reminders.map { r -> [String: AnyEncodable] in
            [
                "ek_reminder_id": AnyEncodable(r.calendarItemIdentifier),
                "title": AnyEncodable(r.title ?? ""),
                "completed": AnyEncodable(r.isCompleted),
                "list_name": AnyEncodable(r.calendar?.title ?? "")
            ]
        }
        let json = encodeJSON(["reminders": dtos]) ?? "{}"
        return .ok(payloadJSON: json)
    }

    // MARK: - Internal helpers

    /// Gate-check the entity-type status. Returns `.ok` if the call should
    /// proceed, else a typed CalendarToolResult to short-circuit the tool.
    private func gateCheck(scope: EKPermissionScope) async -> CalendarToolResult {
        // Always re-read live status — never trust a cached value across
        // foreground transitions (researcher landmine).
        let status = statusProvider(scope.entityType)
        lastKnownStatus[scope.entityType] = status
        switch status {
        case .fullAccess, .writeOnly:
            return .ok(payloadJSON: "")
        case .notDetermined:
            return .permissionRequired(scope: scope)
        case .denied, .restricted:
            return .denied(scope)
        @unknown default:
            // Future iOS versions: treat unknown as denied so we never
            // accidentally proceed without permission.
            return .denied(scope)
        }
    }

    private func registerObservers() {
        guard !observersRegistered else { return }
        observersRegistered = true

        let center = NotificationCenter.default
        // EKEventStoreChanged: fires on any change to the event store,
        // including permission grants/revokes that come through Settings.
        let storeChanged = Notification.Name.EKEventStoreChanged
        Task.detached { [weak self] in
            let stream = center.notifications(named: storeChanged)
            for await _ in stream {
                await self?.refreshIfAuthChanged()
            }
        }

        #if canImport(UIKit)
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
