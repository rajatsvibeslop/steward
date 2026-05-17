//
//  ModesSection.swift
//  Steward — Track E
//
//  Designer §3.3. Mercy and pause toggles. Engaging shows a duration picker;
//  disengaging is one tap (no "Are you sure?" — §3.3 forbids friction).
//

import SwiftUI

struct ModesSection: View {
    let settings: Settings?
    var onMutate: (@escaping @Sendable (inout Settings) -> Void) -> Void

    @State private var pickingMercy: Bool = false
    @State private var pickingPause: Bool = false

    var body: some View {
        Section("MODES") {
            mercyRow
            pauseRow
        }
        .confirmationDialog(
            "Engage mercy mode",
            isPresented: $pickingMercy,
            titleVisibility: .visible
        ) {
            modeButtons(forMercy: true)
        } message: {
            Text("Softer nudges, fewer of them.\nNo reviewing gaps.\n\nFor how long?")
        }
        .confirmationDialog(
            "Pause Steward",
            isPresented: $pickingPause,
            titleVisibility: .visible
        ) {
            modeButtons(forMercy: false)
        } message: {
            Text("All proactive nudges stop.\nYour own calendar/reminder commitments still fire — Steward just stays quiet.\n\nFor how long?")
        }
    }

    @ViewBuilder
    private var mercyRow: some View {
        Toggle(isOn: Binding(
            get: { settings?.mercyModeUntil != nil && (settings?.mercyModeUntil ?? .distantPast) > Date() },
            set: { newValue in
                if newValue {
                    pickingMercy = true
                } else {
                    onMutate { $0.mercyModeUntil = nil }
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mercy mode")
                if let until = settings?.mercyModeUntil, until > Date() {
                    Text(activeCaption(until: until, mercy: true))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var pauseRow: some View {
        Toggle(isOn: Binding(
            get: { settings?.pauseUntil != nil && (settings?.pauseUntil ?? .distantPast) > Date() },
            set: { newValue in
                if newValue {
                    pickingPause = true
                } else {
                    onMutate { $0.pauseUntil = nil }
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pause")
                if let until = settings?.pauseUntil, until > Date() {
                    Text(activeCaption(until: until, mercy: false))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func modeButtons(forMercy: Bool) -> some View {
        let now = Date()
        Button("The rest of today") {
            engage(forMercy: forMercy, until: Calendar.autoupdatingCurrent.startOfDay(for: now).addingTimeInterval(86_400 - 1))
        }
        if forMercy {
            Button("3 days") {
                engage(forMercy: true, until: now.addingTimeInterval(3 * 86_400))
            }
        } else {
            Button("Until tomorrow morning") {
                let tmw = Calendar.autoupdatingCurrent.startOfDay(for: now).addingTimeInterval(86_400 + 7 * 3600)
                engage(forMercy: false, until: tmw)
            }
        }
        Button("1 week") {
            engage(forMercy: forMercy, until: now.addingTimeInterval(7 * 86_400))
        }
        Button("Until I turn it off") {
            engage(forMercy: forMercy, until: now.addingTimeInterval(365 * 86_400))
        }
        Button("Cancel", role: .cancel) {}
    }

    private func engage(forMercy: Bool, until: Date) {
        onMutate { settings in
            if forMercy {
                settings.mercyModeUntil = until
            } else {
                settings.pauseUntil = until
            }
        }
    }

    private func activeCaption(until: Date, mercy: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let when = formatter.string(from: until)
        if mercy {
            return "On until \(when). Steward is gentler right now."
        }
        return "Paused until \(when). Calendar and your own reminders still fire."
    }
}
