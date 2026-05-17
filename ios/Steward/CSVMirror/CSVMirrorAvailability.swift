//
//  CSVMirrorAvailability.swift
//  Steward
//
//  The CSV mirror prefers iCloud Drive's ubiquity container; when that
//  container can't be resolved (iCloud Drive switched off, no signed-in
//  iCloud account, simulator without iCloud, etc.) the boot path falls back
//  to the app sandbox's Application Support directory.
//
//  v1 silently degraded to the sandbox: Settings copy still said "Mirrors
//  your instruments to Steward/" which made users on Mac/iPad expect a
//  visible Steward folder under iCloud Drive that wasn't there — nemesis
//  caveat C, trust erosion against the abstraction-floor principle.
//
//  This file is the single source of truth for which side of that branch
//  we're on. The bootstrap publishes the resolved state once, and Settings
//  (plus any other surface that wants to be honest about it) reads it
//  synchronously off the main actor.
//

import Foundation

/// Where the CSV mirror's `rootURL` actually lives on this device, right now.
///
/// The associated value is the iCloud-Drive folder name as it would appear
/// to the user — `Steward` by default. We keep it as a plain string instead
/// of the resolved file URL because Settings copy only ever needs the user
/// facing name; the file URL belongs to `CSVMirrorPaths`.
enum CSVMirrorAvailability: Sendable, Equatable {
    /// Ubiquity container resolved cleanly. The user will see a Steward
    /// folder under iCloud Drive on every signed-in device.
    case iCloud(folderName: String)
    /// Ubiquity container was nil → we wrote to Application Support inside
    /// the app sandbox. Files exist on-device but never sync.
    case localSandbox(folderName: String)
    /// User turned the mirror off in Settings. No folder, no banner —
    /// the toggle itself is the explanation.
    case disabled

    /// True iff Settings should surface the "iCloud is off — saving locally"
    /// banner. Disabled doesn't qualify: if the user toggled the mirror off
    /// themselves there's nothing to apologise for.
    var requiresFallbackBanner: Bool {
        if case .localSandbox = self { return true }
        return false
    }

    /// Footnote copy under the "iCloud Drive mirror" toggle. Differentiates
    /// between "you'll see this on every device" and "this device only" so
    /// the user is never misled into expecting cross-device sync that
    /// isn't happening.
    func captureFootnoteCopy() -> String? {
        switch self {
        case .iCloud(let folder):
            return "Mirrors your instruments to iCloud Drive → \(folder)/. "
                + "Open them in Numbers on iPhone, iPad, or Mac."
        case .localSandbox:
            return "Mirrors to this device only. Turn on iCloud Drive in "
                + "iOS Settings to share across devices."
        case .disabled:
            return nil
        }
    }

    /// One-line banner shown above the CAPTURE section when the user thinks
    /// they have iCloud sync but doesn't. Nil for the other two states.
    var fallbackBannerCopy: String? {
        guard requiresFallbackBanner else { return nil }
        return "iCloud Drive is off — Outkeep is saving locally only."
    }
}

/// Pure classifier so we can unit-test the iCloud vs. sandbox decision
/// without mocking `FileManager`. The bootstrap injects a probe that wraps
/// `FileManager.default.url(forUbiquityContainerIdentifier:)`; tests inject
/// a synthetic probe.
enum CSVMirrorAvailabilityClassifier {
    /// Decide which mirror root applies given the settings flag, the iCloud
    /// folder name, and a probe that returns true iff the ubiquity container
    /// resolved.
    static func classify(
        mirrorEnabled: Bool,
        folderName: String,
        ubiquityContainerAvailable: () -> Bool
    ) -> CSVMirrorAvailability {
        guard mirrorEnabled else { return .disabled }
        if ubiquityContainerAvailable() {
            return .iCloud(folderName: folderName)
        }
        return .localSandbox(folderName: folderName)
    }
}

/// Process-wide holder for the resolved availability. Written once at
/// bootstrap (BackgroundServicesBootstrap.run); read off the main actor by Settings
/// + Today. Read-mostly so we use an isolated actor and surface a synchronous
/// main-actor snapshot via `@MainActor` mirror updated when the boot path
/// publishes — same pattern as `VoiceCaptureRegistry.current`.
@MainActor
enum CSVMirrorAvailabilityRegistry {
    /// Current availability. Defaults to `.disabled` so first paint never
    /// shows a misleading "saving locally" banner before bootstrap finishes;
    /// once bootstrap calls `publish` (or `publishDisabled` for the off path)
    /// the real value flows out.
    private(set) static var current: CSVMirrorAvailability = .disabled

    /// Called by `BackgroundServicesBootstrap.run` after it has chosen the CSV root.
    static func publish(_ availability: CSVMirrorAvailability) {
        current = availability
        NotificationCenter.default.post(
            name: .csvMirrorAvailabilityChanged,
            object: nil
        )
    }
}

extension Notification.Name {
    /// Posted on the main actor whenever `CSVMirrorAvailabilityRegistry.current`
    /// changes. Settings observes this so the banner appears the moment the
    /// bootstrap finishes — no need for a busy-wait or polling.
    static let csvMirrorAvailabilityChanged = Notification.Name(
        "Steward.csvMirrorAvailabilityChanged"
    )
}
