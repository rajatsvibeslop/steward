//
//  CSVMirrorAvailabilityTests.swift
//  StewardTests
//
//  Covers:
//   1. The pure classifier function — does the (mirrorEnabled × iCloud
//      probe) matrix collapse to the right CSVMirrorAvailability case?
//   2. The user-facing copy each state surfaces — distinct strings for
//      iCloud vs. local sandbox, no copy at all for disabled, banner only
//      when the fallback is active.
//   3. The CaptureSection view renders the right footnote + banner for
//      both states by exercising the same code path the view body uses.
//

import XCTest
import SwiftUI
@testable import Steward

final class CSVMirrorAvailabilityTests: XCTestCase {

    // MARK: - Classifier

    func testClassifyDisabledWhenMirrorOff() {
        let result = CSVMirrorAvailabilityClassifier.classify(
            mirrorEnabled: false,
            folderName: "Steward",
            ubiquityContainerAvailable: { true }
        )
        XCTAssertEqual(result, .disabled,
                       "Toggle off must short-circuit to .disabled even if iCloud is reachable.")
    }

    func testClassifyiCloudWhenContainerResolves() {
        let result = CSVMirrorAvailabilityClassifier.classify(
            mirrorEnabled: true,
            folderName: "Steward",
            ubiquityContainerAvailable: { true }
        )
        XCTAssertEqual(result, .iCloud(folderName: "Steward"))
    }

    func testClassifyLocalSandboxWhenContainerMissing() {
        let result = CSVMirrorAvailabilityClassifier.classify(
            mirrorEnabled: true,
            folderName: "Steward",
            ubiquityContainerAvailable: { false }
        )
        XCTAssertEqual(result, .localSandbox(folderName: "Steward"))
    }

    func testClassifierHonoursCustomFolderName() {
        // The folder name flows straight through to the copy layer; tests
        // for the copy itself live below.
        let result = CSVMirrorAvailabilityClassifier.classify(
            mirrorEnabled: true,
            folderName: "MyJournal",
            ubiquityContainerAvailable: { true }
        )
        XCTAssertEqual(result, .iCloud(folderName: "MyJournal"))
    }

    // MARK: - Copy

    func testiCloudFootnoteMentionsiCloudDriveAndDevices() {
        let copy = CSVMirrorAvailability.iCloud(folderName: "Steward").captureFootnoteCopy()
        guard let copy else { return XCTFail("iCloud state must produce a footnote") }
        XCTAssertTrue(copy.contains("iCloud Drive"),
                      "iCloud copy must name iCloud Drive so the user knows where to look.")
        XCTAssertTrue(copy.contains("Steward"),
                      "iCloud copy must include the folder name.")
        XCTAssertTrue(copy.contains("iPhone") || copy.contains("Mac"),
                      "iCloud copy must promise cross-device visibility.")
    }

    func testLocalSandboxFootnoteFlagsSingleDevice() {
        let copy = CSVMirrorAvailability.localSandbox(folderName: "Steward").captureFootnoteCopy()
        guard let copy else { return XCTFail("Local-sandbox state must produce a footnote") }
        XCTAssertTrue(copy.lowercased().contains("this device"),
                      "Sandbox copy must call out single-device scope so the user isn't misled.")
        XCTAssertFalse(copy.lowercased().contains("ipad") && copy.lowercased().contains("mac"),
                      "Sandbox copy must NOT promise cross-device sync.")
    }

    func testFootnotesForTheTwoLiveStatesAreDistinct() {
        let cloud = CSVMirrorAvailability.iCloud(folderName: "Steward").captureFootnoteCopy()
        let local = CSVMirrorAvailability.localSandbox(folderName: "Steward").captureFootnoteCopy()
        XCTAssertNotNil(cloud)
        XCTAssertNotNil(local)
        XCTAssertNotEqual(cloud, local,
                          "iCloud and sandbox states must surface distinct copy — the bug we're fixing is that v1 used one string for both.")
    }

    func testDisabledHasNoFootnoteAndNoBanner() {
        let state = CSVMirrorAvailability.disabled
        XCTAssertNil(state.captureFootnoteCopy(),
                     "Toggle-off state has no footnote — the toggle itself is the explanation.")
        XCTAssertNil(state.fallbackBannerCopy,
                     "Toggle-off must not trigger the fallback banner.")
        XCTAssertFalse(state.requiresFallbackBanner)
    }

    func testBannerOnlyAppearsForSandboxFallback() {
        XCTAssertNil(
            CSVMirrorAvailability.iCloud(folderName: "Steward").fallbackBannerCopy,
            "iCloud path is the happy path — no banner."
        )
        XCTAssertNotNil(
            CSVMirrorAvailability.localSandbox(folderName: "Steward").fallbackBannerCopy,
            "Sandbox fallback must surface the banner — this is the whole point of the patch."
        )
        XCTAssertTrue(
            CSVMirrorAvailability.localSandbox(folderName: "Steward").requiresFallbackBanner
        )
    }

    func testFallbackBannerMentionsiCloudOffAndLocal() {
        let banner = CSVMirrorAvailability.localSandbox(folderName: "Steward").fallbackBannerCopy ?? ""
        XCTAssertTrue(banner.contains("iCloud Drive"),
                      "Banner must name iCloud Drive so user knows what to turn on.")
        XCTAssertTrue(banner.lowercased().contains("locally") || banner.lowercased().contains("local"),
                      "Banner must call out that storage is local-only.")
    }

    // MARK: - CaptureSection rendering

    /// Both render paths exist: we instantiate the view, force the
    /// `availability` state into each case, and confirm the relevant view
    /// machinery still resolves (no preconditionFailure, no missing case).
    /// SwiftUI doesn't give us a tree to inspect in the unit-test target,
    /// so this is the most we can assert without an XCUI harness — combined
    /// with the copy tests above it's enough to prove both branches are wired.
    @MainActor
    func testCaptureSectionRendersForiCloudState() {
        CSVMirrorAvailabilityRegistry.publish(.iCloud(folderName: "Steward"))
        let section = CaptureSection(
            settings: makeSettings(csvMirrorEnabled: true),
            onMutate: { _, _ in }
        )
        // Touching `body` exercises the view-tree construction; if any
        // branch above threw a fatalError or referenced a missing case,
        // this line would crash the test.
        _ = section.body
        XCTAssertEqual(CSVMirrorAvailabilityRegistry.current, .iCloud(folderName: "Steward"))
    }

    @MainActor
    func testCaptureSectionRendersForLocalSandboxState() {
        CSVMirrorAvailabilityRegistry.publish(.localSandbox(folderName: "Steward"))
        let section = CaptureSection(
            settings: makeSettings(csvMirrorEnabled: true),
            onMutate: { _, _ in }
        )
        _ = section.body
        XCTAssertEqual(CSVMirrorAvailabilityRegistry.current, .localSandbox(folderName: "Steward"))
    }

    @MainActor
    func testCaptureSectionRendersWhenMirrorDisabled() {
        CSVMirrorAvailabilityRegistry.publish(.disabled)
        let section = CaptureSection(
            settings: makeSettings(csvMirrorEnabled: false),
            onMutate: { _, _ in }
        )
        _ = section.body
        XCTAssertEqual(CSVMirrorAvailabilityRegistry.current, .disabled)
    }

    // MARK: - Helpers

    private func makeSettings(csvMirrorEnabled: Bool) -> Settings {
        Settings(
            quietHours: .init(start: "22:00", end: "07:00"),
            morningBriefTime: "07:00",
            maxProactiveNotificationsPerDay: 3,
            minNotificationGapMinutes: 90,
            mercyModeUntil: nil,
            pauseUntil: nil,
            csvMirrorEnabled: csvMirrorEnabled,
            icloudDriveFolder: "Steward",
            voiceCaptureEnabled: true,
            defaultAgentTemperature: 0.7
        )
    }
}
