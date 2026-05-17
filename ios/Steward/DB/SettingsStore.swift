//
//  SettingsStore.swift
//  Steward
//
//  Serialized read/write surface for the single-row `settings` table.
//  Addendum §4 hard reject #16: all settings mutations must go through one
//  actor so concurrent tool calls can't lose updates. Pods B / D / F all
//  mutate disjoint fields; the actor lets them do so safely.
//
//  Wire-format note: the on-disk JSON is snake_case per spec §5. We
//  use `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` and the
//  matching encoder strategy so Swift sees idiomatic camelCase. Nested
//  fields like `quietHours.start` / `quietHours.end` stay lowercase already.
//

import Foundation
import GRDB

/// Strongly-typed mirror of the JSON blob in `settings.settings_json`.
struct Settings: Codable, Sendable, Equatable {
    struct QuietHours: Codable, Sendable, Equatable {
        /// "HH:mm" wall-clock string, autoupdating local timezone.
        var start: String
        var end: String
    }

    var quietHours: QuietHours
    /// "HH:mm" wall-clock string for the daily morning brief.
    var morningBriefTime: String
    var maxProactiveNotificationsPerDay: Int
    var minNotificationGapMinutes: Int
    var mercyModeUntil: Date?
    var pauseUntil: Date?
    var csvMirrorEnabled: Bool
    var icloudDriveFolder: String
    var voiceCaptureEnabled: Bool
    var defaultAgentTemperature: Double
}

enum SettingsStoreError: Error, CustomStringConvertible {
    case rowMissing
    case decodingFailed(underlying: Error)
    case encodingFailed(underlying: Error)

    var description: String {
        switch self {
        case .rowMissing:
            return "settings table has no row with id=1 (migration seed missing?)"
        case .decodingFailed(let underlying):
            return "Settings JSON decode failed: \(underlying)"
        case .encodingFailed(let underlying):
            return "Settings JSON encode failed: \(underlying)"
        }
    }
}

/// Identifies which `Settings` field a user-driven UI mutation touched.
/// The raw value is the wire-format field name written into the
/// `settings_change` event payload (snake_case to match on-disk JSON).
///
/// Used only by the user-UI path; agent tools (`mercy_mode.engage` etc.)
/// continue to write their own `kind="mercy_mode_engage"`-style events via
/// `EventLog.append` and DO NOT route through this enum. v1.1 patch
/// (settings-audit): closes the gap where SwiftUI toggle / picker mutations
/// silently updated `settings` without leaving any audit trail.
enum SettingsAuditField: String, Sendable, Equatable {
    case mercyModeUntil                   = "mercy_mode_until"
    case pauseUntil                       = "pause_until"
    case quietHours                       = "quiet_hours"
    case morningBriefTime                 = "morning_brief_time"
    case maxProactiveNotificationsPerDay  = "max_proactive_notifications_per_day"
    case minNotificationGapMinutes        = "min_notification_gap_minutes"
    case voiceCaptureEnabled              = "voice_capture_enabled"
    case csvMirrorEnabled                 = "csv_mirror_enabled"

    /// JSON-serialisable view of this field's current value in `s`. Dates
    /// render as ISO-8601 strings (matching the agent-tool payload format
    /// used by `MercyModeEngageTool`), nil renders as `NSNull` (so it
    /// serialises to JSON `null`), and `QuietHours` flattens to a
    /// `{start, end}` dict.
    func jsonValue(of s: Settings) -> Any {
        switch self {
        case .mercyModeUntil:
            return s.mercyModeUntil.map(Self.iso8601) ?? NSNull()
        case .pauseUntil:
            return s.pauseUntil.map(Self.iso8601) ?? NSNull()
        case .quietHours:
            return ["start": s.quietHours.start, "end": s.quietHours.end]
        case .morningBriefTime:
            return s.morningBriefTime
        case .maxProactiveNotificationsPerDay:
            return s.maxProactiveNotificationsPerDay
        case .minNotificationGapMinutes:
            return s.minNotificationGapMinutes
        case .voiceCaptureEnabled:
            return s.voiceCaptureEnabled
        case .csvMirrorEnabled:
            return s.csvMirrorEnabled
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()
    fileprivate static func iso8601(_ d: Date) -> String { isoFormatter.string(from: d) }
}

/// Actor-serialized accessor for the `settings` row.
///
/// `load()` returns the cached value if present, decoding from disk on first
/// access. `update(_:)` performs a read-mutate-write inside a single
/// `db.write { }` block and refreshes the cache. Tests use
/// `invalidateCache()` to force a re-read.
///
/// Hard rule (addendum §1.11): raw `UPDATE settings SET ...` outside this
/// file is a §4 hard reject. Every other pod (B / D / F) goes through
/// `SettingsStore.shared.update`.
actor SettingsStore {
    static let shared = SettingsStore()

    private let provider: DatabaseProvider
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var cached: Settings?

    init(provider: DatabaseProvider = .shared) {
        self.provider = provider

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.dateEncodingStrategy = .iso8601
        // Stable on-disk ordering helps the iCloud CSV mirror present
        // diff-able settings.json snapshots later (the CSV mirror layer may render this).
        // Locked in addendum §1.11.
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    /// Returns the current settings. Cached after first read.
    func load() async throws -> Settings {
        if let cached { return cached }
        let db = try await provider.database()
        let dec = self.decoder
        let loaded = try await db.read { dbase in
            try Self.fetch(db: dbase, decoder: dec)
        }
        cached = loaded
        return loaded
    }

    /// Atomic read-modify-write. Mutation runs inside a single `db.write { }`
    /// block; the cache is refreshed and the new value returned. Two
    /// concurrent `update` calls serialize on the actor — last-writer wins on
    /// overlapping fields, but neither call sees a torn read.
    @discardableResult
    func update(_ mutate: @escaping @Sendable (inout Settings) -> Void) async throws -> Settings {
        let db = try await provider.database()
        let dec = self.decoder
        let enc = self.encoder
        let updated = try await db.write { dbase in
            var current = try Self.fetch(db: dbase, decoder: dec)
            mutate(&current)
            let data: Data
            do {
                data = try enc.encode(current)
            } catch {
                throw SettingsStoreError.encodingFailed(underlying: error)
            }
            guard let json = String(data: data, encoding: .utf8) else {
                throw SettingsStoreError.encodingFailed(
                    underlying: NSError(domain: "Steward.SettingsStore", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "UTF-8 encode failed"])
                )
            }
            try dbase.execute(
                sql: "UPDATE settings SET settings_json = ? WHERE id = 1",
                arguments: [json]
            )
            return current
        }
        cached = updated
        return updated
    }

    /// Atomic mutate + audit-log emit. Same semantics as `update(_:)` except
    /// that, before commit, this method also appends a `settings_change`
    /// event row (actor=`user`) describing the field change. The settings
    /// write and the event insert live in a single `db.write { }` block so
    /// the addendum's append-only invariant holds: either both land or
    /// neither does. If the mutation didn't actually change the audited
    /// field's value (e.g. user opens a picker, taps Save without moving
    /// it), no event row is written — matches the "no duplicate event for
    /// at-rest mutation" requirement from the v1.1 patch DoD.
    @discardableResult
    func update(
        audit: SettingsAuditField,
        at now: Date = Date(),
        _ mutate: @escaping @Sendable (inout Settings) -> Void
    ) async throws -> Settings {
        let db = try await provider.database()
        let dec = self.decoder
        let enc = self.encoder
        let updated = try await db.write { dbase -> Settings in
            let prior = try Self.fetch(db: dbase, decoder: dec)
            var current = prior
            mutate(&current)
            let data: Data
            do {
                data = try enc.encode(current)
            } catch {
                throw SettingsStoreError.encodingFailed(underlying: error)
            }
            guard let json = String(data: data, encoding: .utf8) else {
                throw SettingsStoreError.encodingFailed(
                    underlying: NSError(domain: "Steward.SettingsStore", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "UTF-8 encode failed"])
                )
            }
            try dbase.execute(
                sql: "UPDATE settings SET settings_json = ? WHERE id = 1",
                arguments: [json]
            )

            // Audit log: skip emit if the audited field's value did not
            // actually change. We compare JSON-canonicalised forms so e.g.
            // `Date(...)` equality survives the ISO-8601 round-trip we'd
            // store on disk.
            let priorValue = audit.jsonValue(of: prior)
            let newValue = audit.jsonValue(of: current)
            if Self.jsonEqual(priorValue, newValue) {
                return current
            }

            let payload: [String: Any] = [
                "field": audit.rawValue,
                "prior": priorValue,
                "new": newValue,
            ]
            let payloadJSON: String
            do {
                let pData = try JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.sortedKeys]
                )
                guard let s = String(data: pData, encoding: .utf8) else {
                    throw SettingsStoreError.encodingFailed(
                        underlying: NSError(
                            domain: "Steward.SettingsStore", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "settings_change payload UTF-8 encode failed"]
                        )
                    )
                }
                payloadJSON = s
            } catch let e as SettingsStoreError {
                throw e
            } catch {
                throw SettingsStoreError.encodingFailed(underlying: error)
            }

            // `actor=user` is permitted to have nil reasoning per the events
            // CHECK constraint (Migrations.swift §events) — settings changes
            // are user intent, not agent inference, so we keep reasoning
            // empty rather than inventing prose.
            _ = try EventLog.append(
                actor: .user,
                kind: "settings_change",
                payloadJSON: payloadJSON,
                source: "ui",
                at: now,
                in: dbase
            )
            return current
        }
        cached = updated
        return updated
    }

    /// Test seam — discards the cache so the next `load` re-reads from disk.
    func invalidateCache() {
        cached = nil
    }

    // MARK: - Private

    /// Canonical-JSON comparison for two values coming out of
    /// `SettingsAuditField.jsonValue(of:)`. Wrapping in a single-key dict
    /// works around `JSONSerialization`'s "top-level must be array/dict"
    /// requirement while keeping the comparison stable (sortedKeys output).
    private static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        let aData = try? JSONSerialization.data(
            withJSONObject: ["v": a], options: [.sortedKeys]
        )
        let bData = try? JSONSerialization.data(
            withJSONObject: ["v": b], options: [.sortedKeys]
        )
        return aData != nil && aData == bData
    }

    private static func fetch(db: Database, decoder: JSONDecoder) throws -> Settings {
        guard let json = try String.fetchOne(
            db,
            sql: "SELECT settings_json FROM settings WHERE id = 1"
        ) else {
            throw SettingsStoreError.rowMissing
        }
        guard let data = json.data(using: .utf8) else {
            throw SettingsStoreError.decodingFailed(
                underlying: NSError(domain: "Steward.SettingsStore", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "UTF-8 decode failed"])
            )
        }
        do {
            return try decoder.decode(Settings.self, from: data)
        } catch {
            throw SettingsStoreError.decodingFailed(underlying: error)
        }
    }
}
