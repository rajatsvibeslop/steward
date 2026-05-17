//
//  CaptureSection.swift
//  Steward
//
//  Designer §3.6. Voice + iCloud mirror toggles.
//
//  v1.1 patch: distinguishes the iCloud-Drive-on case from the silent
//  Application-Support fallback case. v1 always told the user "Mirrors your
//  instruments to Steward/" even when iCloud Drive was off and nothing of
//  the kind was happening — nemesis caveat C. Reads the resolved state from
//  `CSVMirrorAvailabilityRegistry` (published once by BackgroundServicesBootstrap) and
//  re-renders when bootstrap posts `csvMirrorAvailabilityChanged`.
//

import SwiftUI

struct CaptureSection: View {
    let settings: Settings?
    /// Callback shape: `(audited-field, mutate)`. SettingsView routes to
    /// `SettingsViewModel.update(audit:_:)` so toggling voice / iCloud mirror
    /// from the UI emits a `settings_change` audit event (v1.1 patch).
    var onMutate: (SettingsAuditField, @escaping @Sendable (inout Settings) -> Void) -> Void

    /// Mirrors `CSVMirrorAvailabilityRegistry.current`. Re-keyed on the
    /// `csvMirrorAvailabilityChanged` notification so the section updates the
    /// instant bootstrap finishes resolving the iCloud container.
    @State private var availability: CSVMirrorAvailability = CSVMirrorAvailabilityRegistry.current

    var body: some View {
        Group {
            if let banner = availability.fallbackBannerCopy {
                Section {
                    Label(banner, systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.icloud_fallback_banner")
                }
            }
            Section("CAPTURE") {
                Toggle(
                    "Voice input",
                    isOn: Binding(
                        get: { settings?.voiceCaptureEnabled ?? true },
                        set: { newValue in
                            onMutate(.voiceCaptureEnabled) { $0.voiceCaptureEnabled = newValue }
                        }
                    )
                )
                Toggle(
                    "iCloud Drive mirror",
                    isOn: Binding(
                        get: { settings?.csvMirrorEnabled ?? true },
                        set: { newValue in
                            onMutate(.csvMirrorEnabled) { $0.csvMirrorEnabled = newValue }
                        }
                    )
                )
                if settings?.csvMirrorEnabled == true,
                   let copy = effectiveFootnote()
                {
                    Text(copy)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.icloud_footnote")
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .csvMirrorAvailabilityChanged)
        ) { _ in
            availability = CSVMirrorAvailabilityRegistry.current
        }
    }

    /// The footnote text under the mirror toggle. We honour the registry's
    /// resolved state, but when it's still `.disabled` at first paint and the
    /// user has the toggle on, we fall back to a generic line built from the
    /// configured folder so the section is never blank during bootstrap.
    private func effectiveFootnote() -> String? {
        if let copy = availability.captureFootnoteCopy() {
            return copy
        }
        guard let folder = settings?.icloudDriveFolder else { return nil }
        return "Mirrors your instruments to iCloud Drive → \(folder)/. "
            + "Open them in Numbers on iPhone, iPad, or Mac."
    }
}
