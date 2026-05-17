//
//  EventKitTypes.swift
//  Steward
//
//  Shared types for the EventKit tool surface (calendar.* and reminder.*).
//  Addendum §1.9 contract.
//

import Foundation
import EventKit

// MARK: - Permission scope (LLM/UI/Audit vocabulary)

enum EKPermissionScope: String, Codable, Sendable, Equatable, CaseIterable {
    case calendarFullAccess
    case calendarWriteOnly
    case remindersFullAccess
    case remindersWriteOnly

    var entityType: EKEntityType {
        switch self {
        case .calendarFullAccess, .calendarWriteOnly: return .event
        case .remindersFullAccess, .remindersWriteOnly: return .reminder
        }
    }
}

// MARK: - CalendarToolResult

/// Hybrid permission lifecycle result type (addendum §1.9). The LLM only sees
/// `.ok`, `.permissionDenied`, and `.systemError` (hard reject #19 —
/// `.permissionRequired` is intercepted by the UI for the inline-grant flow).
///
/// `.systemError` is distinct from `.permissionDenied` because misclassifying
/// a transient EventKit save failure as "user revoked Calendar" sends the LLM
/// down the wrong recovery path (it'll politely apologize and offer to skip
/// instead of suggesting the user check their iCloud sync).
enum CalendarToolResult: Sendable {
    case ok(payloadJSON: String)
    case permissionRequired(scope: EKPermissionScope)
    case permissionDenied(scope: EKPermissionScope, hint: String)
    case systemError(scope: EKPermissionScope, hint: String)
}

extension CalendarToolResult {
    /// LLM-safe wire representation. `permissionRequired` is omitted so this
    /// surface cannot leak it back into the model.
    func wireJSON() throws -> String? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        struct Body: Codable {
            let status: String
            let scope: String
            let hint: String
        }
        switch self {
        case .ok(let payload):
            return payload
        case .permissionRequired:
            // Hard reject #19: never serialize this for the LLM.
            return nil
        case .permissionDenied(let scope, let hint):
            let data = try enc.encode(Body(status: "permission_denied",
                                            scope: scope.rawValue, hint: hint))
            return String(data: data, encoding: .utf8)
        case .systemError(let scope, let hint):
            let data = try enc.encode(Body(status: "system_error",
                                            scope: scope.rawValue, hint: hint))
            return String(data: data, encoding: .utf8)
        }
    }

    var isPermissionRequired: Bool {
        if case .permissionRequired = self { return true }
        return false
    }
}

// MARK: - Tool argument structs

struct CalendarReadArgs: Codable, Sendable {
    var start: Date
    var end: Date
    var calendarName: String?
    var reasoning: String?    // optional for read (read isn't a mutation)
}

struct CalendarWriteArgs: Codable, Sendable {
    var title: String
    var startDate: Date
    var endDate: Date
    var notes: String?
    var location: String?
    var isAllDay: Bool?
    var calendarName: String?
    var reasoning: String
}

struct CalendarModifyArgs: Codable, Sendable {
    struct Patch: Codable, Sendable {
        var title: String?
        var startDate: Date?
        var endDate: Date?
        var notes: String?
        var location: String?
        var isAllDay: Bool?
    }
    var ekEventID: String
    var patch: Patch
    var reasoning: String
}

struct CalendarDeleteArgs: Codable, Sendable {
    var ekEventID: String
    var reasoning: String
}

struct ReminderCreateArgs: Codable, Sendable {
    var title: String
    var dueDate: Date?
    var notes: String?
    var listName: String?
    var reasoning: String
}

struct ReminderCompleteArgs: Codable, Sendable {
    var ekReminderID: String
    var reasoning: String
}

struct ReminderListArgs: Codable, Sendable {
    var listName: String?
    var completed: Bool?
}

// MARK: - Tool error helpers

extension CalendarToolResult {
    static func denied(_ scope: EKPermissionScope) -> CalendarToolResult {
        let hint: String
        switch scope {
        case .calendarFullAccess, .calendarWriteOnly:
            hint = "Calendar access is off. Open Settings → Privacy → Calendars → Steward to grant access."
        case .remindersFullAccess, .remindersWriteOnly:
            hint = "Reminders access is off. Open Settings → Privacy → Reminders → Steward to grant access."
        }
        return .permissionDenied(scope: scope, hint: hint)
    }
}
