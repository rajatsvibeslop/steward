//
//  SettingsStoreTests.swift
//  StewardTests
//
//  Covers the SettingsStore actor:
//  - Initial load returns the spec §5 default-seeded values.
//  - update(_:) round-trips a mutation.
//  - Concurrent updates from many tasks all linearize through the actor;
//    the final row is consistent and no field is silently lost.
//

import XCTest
import GRDB
@testable import Steward

final class SettingsStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Spin up an isolated DatabaseProvider against a temp file so concurrent
    /// runs of this suite don't fight over the real shared instance.
    private func makeStore() async throws -> (SettingsStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steward-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("steward.sqlite")
        let provider = DatabaseProvider(location: .file(dbURL))
        // Force migration up front so concurrent callers don't race the
        // "opening" critical section in this test setup.
        _ = try await provider.database()
        return (SettingsStore(provider: provider), dbURL)
    }

    // MARK: - Tests

    func test_initialLoadReturnsSeededDefaults() async throws {
        let (store, _) = try await makeStore()
        let s = try await store.load()
        XCTAssertEqual(s.quietHours.start, "22:00")
        XCTAssertEqual(s.quietHours.end, "05:00")
        XCTAssertEqual(s.morningBriefTime, "07:00")
        XCTAssertEqual(s.maxProactiveNotificationsPerDay, 3)
        XCTAssertEqual(s.minNotificationGapMinutes, 90)
        XCTAssertNil(s.mercyModeUntil)
        XCTAssertNil(s.pauseUntil)
        XCTAssertTrue(s.csvMirrorEnabled)
        XCTAssertEqual(s.icloudDriveFolder, "Steward")
        XCTAssertTrue(s.voiceCaptureEnabled)
        XCTAssertEqual(s.defaultAgentTemperature, 0.7, accuracy: 0.0001)
    }

    func test_updateRoundTripsAcrossLoad() async throws {
        let (store, _) = try await makeStore()
        let target = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15-ish

        let returned = try await store.update { s in
            s.maxProactiveNotificationsPerDay = 5
            s.mercyModeUntil = target
            s.voiceCaptureEnabled = false
            s.quietHours.start = "23:00"
        }

        XCTAssertEqual(returned.maxProactiveNotificationsPerDay, 5)

        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.maxProactiveNotificationsPerDay, 5)
        let reloadedMercy = try XCTUnwrap(reloaded.mercyModeUntil)
        XCTAssertEqual(reloadedMercy.timeIntervalSince1970,
                       target.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(reloaded.voiceCaptureEnabled, false)
        XCTAssertEqual(reloaded.quietHours.start, "23:00")
        // Unchanged fields untouched.
        XCTAssertEqual(reloaded.quietHours.end, "05:00")
        XCTAssertEqual(reloaded.morningBriefTime, "07:00")
    }

    func test_concurrentUpdates_preserveSingleRow_andAllSucceed() async throws {
        let (store, dbURL) = try await makeStore()

        // 50 concurrent updates, each bumping a disjoint counter-like field.
        // The actor must serialize them; if it doesn't, the final increment
        // value will be < 50 because of lost-update races.
        let iterations = 50
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    _ = try await store.update { s in
                        s.maxProactiveNotificationsPerDay += 1
                    }
                }
            }
            try await group.waitForAll()
        }

        let final = try await store.load()
        XCTAssertEqual(
            final.maxProactiveNotificationsPerDay,
            3 + iterations,
            "concurrent updates were not serialized; settings row lost increments"
        )

        // The CHECK (id=1) constraint must still hold — exactly one settings row.
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try await queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM settings") ?? 0
            XCTAssertEqual(count, 1, "settings table must still contain exactly one row")
        }
    }

    func test_concurrentDisjointFields_dontStompEachOther() async throws {
        let (store, _) = try await makeStore()

        // Two writers, two different fields, many iterations. Last-write-wins
        // per field is fine; "field A's writer overwrites field B's value"
        // is NOT — that's the read-modify-write race the actor exists to
        // prevent.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<25 {
                    _ = try await store.update { s in
                        s.csvMirrorEnabled.toggle()
                    }
                }
            }
            group.addTask {
                for _ in 0..<25 {
                    _ = try await store.update { s in
                        s.voiceCaptureEnabled.toggle()
                    }
                }
            }
            try await group.waitForAll()
        }

        // 25 toggles each, starting from `true` → both fields end up at
        // `false` iff every toggle landed atomically (25 is odd, so parity
        // flips). If updates raced, the read-modify-write of writer A would
        // overwrite writer B's change to the other field, and one (or both)
        // counters would end up off-parity. Asserting BOTH end at `false`
        // catches lost-update races on either field.
        let final = try await store.load()
        XCTAssertFalse(final.csvMirrorEnabled,
                       "csvMirrorEnabled parity wrong; either a toggle was lost or another writer raced")
        XCTAssertFalse(final.voiceCaptureEnabled,
                       "voiceCaptureEnabled parity wrong; either a toggle was lost or another writer raced")
    }
}
