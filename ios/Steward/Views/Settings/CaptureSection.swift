//
//  CaptureSection.swift
//  Steward — Track E
//
//  Designer §3.6. Voice + iCloud mirror toggles.
//

import SwiftUI

struct CaptureSection: View {
    let settings: Settings?
    var onMutate: (@escaping @Sendable (inout Settings) -> Void) -> Void

    var body: some View {
        Section("CAPTURE") {
            Toggle(
                "Voice input",
                isOn: Binding(
                    get: { settings?.voiceCaptureEnabled ?? true },
                    set: { newValue in onMutate { $0.voiceCaptureEnabled = newValue } }
                )
            )
            Toggle(
                "iCloud Drive mirror",
                isOn: Binding(
                    get: { settings?.csvMirrorEnabled ?? true },
                    set: { newValue in onMutate { $0.csvMirrorEnabled = newValue } }
                )
            )
            if let folder = settings?.icloudDriveFolder {
                Text("Mirrors your instruments to \(folder). Read-only in Numbers unless you edit there.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
