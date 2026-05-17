//
//  TimingSection.swift
//  Steward — Track E
//
//  Designer §3.2. Brief time / quiet hours / nudge cap / min gap. Each row
//  pushes to a detail screen so the Settings list stays scannable.
//

import SwiftUI

struct TimingSection: View {
    let settings: Settings?
    var onMutate: (@escaping @Sendable (inout Settings) -> Void) -> Void

    var body: some View {
        Section("TIMING") {
            NavigationLink {
                MorningBriefTimePicker(
                    initial: settings?.morningBriefTime ?? "07:00",
                    onSave: { newValue in
                        onMutate { $0.morningBriefTime = newValue }
                    }
                )
            } label: {
                row(label: "Morning brief", value: settings?.morningBriefTime ?? "07:00")
            }

            NavigationLink {
                QuietHoursPicker(
                    initial: settings?.quietHours ?? Settings.QuietHours(start: "22:00", end: "05:00"),
                    onSave: { newValue in
                        onMutate { $0.quietHours = newValue }
                    }
                )
            } label: {
                row(
                    label: "Quiet hours",
                    value: "\(settings?.quietHours.start ?? "22:00") – \(settings?.quietHours.end ?? "05:00")"
                )
            }

            NavigationLink {
                NumberStepperView(
                    title: "Max nudges per day",
                    header: "How many nudges per day, max?",
                    body: "Includes the morning brief. Default is 3.",
                    range: 1...6,
                    initial: settings?.maxProactiveNotificationsPerDay ?? 3,
                    step: 1,
                    onSave: { newValue in
                        onMutate { $0.maxProactiveNotificationsPerDay = newValue }
                    }
                )
            } label: {
                row(
                    label: "Max nudges per day",
                    value: "\(settings?.maxProactiveNotificationsPerDay ?? 3)"
                )
            }

            NavigationLink {
                NumberStepperView(
                    title: "Minimum gap between nudges",
                    header: "Minimum time between nudges?",
                    body: nil,
                    range: 30...240,
                    initial: settings?.minNotificationGapMinutes ?? 90,
                    step: 15,
                    onSave: { newValue in
                        onMutate { $0.minNotificationGapMinutes = newValue }
                    }
                )
            } label: {
                row(
                    label: "Minimum gap between nudges",
                    value: "\(settings?.minNotificationGapMinutes ?? 90) min"
                )
            }
        }
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pickers

struct MorningBriefTimePicker: View {
    @State private var selection: Date
    let initial: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initial: String, onSave: @escaping (String) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _selection = State(initialValue: TimingFormat.parse(initial))
    }

    var body: some View {
        Form {
            Section {
                DatePicker("", selection: $selection, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
            } header: {
                Text("When should I send the morning brief?")
            } footer: {
                Text("It fires once a day. You can mute it anytime.")
            }
        }
        .navigationTitle("Morning brief")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    onSave(TimingFormat.format(selection))
                    dismiss()
                }
            }
        }
    }
}

struct QuietHoursPicker: View {
    @State private var startDate: Date
    @State private var endDate: Date
    let initial: Settings.QuietHours
    let onSave: (Settings.QuietHours) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initial: Settings.QuietHours, onSave: @escaping (Settings.QuietHours) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _startDate = State(initialValue: TimingFormat.parse(initial.start))
        _endDate = State(initialValue: TimingFormat.parse(initial.end))
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Start", selection: $startDate, displayedComponents: .hourAndMinute)
                DatePicker("End", selection: $endDate, displayedComponents: .hourAndMinute)
            } header: {
                Text("No nudges between these times.")
            } footer: {
                Text("The morning brief still fires if it falls outside this window.")
            }
        }
        .navigationTitle("Quiet hours")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    onSave(.init(
                        start: TimingFormat.format(startDate),
                        end: TimingFormat.format(endDate)
                    ))
                    dismiss()
                }
            }
        }
    }
}

struct NumberStepperView: View {
    let title: String
    let header: String
    let footerText: String?
    let range: ClosedRange<Int>
    @State private var value: Int
    let step: Int
    let onSave: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        header: String,
        body: String?,
        range: ClosedRange<Int>,
        initial: Int,
        step: Int,
        onSave: @escaping (Int) -> Void
    ) {
        self.title = title
        self.header = header
        self.footerText = body
        self.range = range
        self.step = step
        self.onSave = onSave
        _value = State(initialValue: min(max(initial, range.lowerBound), range.upperBound))
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: $value, in: range, step: step) {
                    HStack {
                        Text(title)
                        Spacer()
                        Text("\(value)").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(header)
            } footer: {
                if let footerText { Text(footerText) } else { EmptyView() }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { onSave(value); dismiss() }
            }
        }
    }
}

// MARK: - "HH:mm" <-> Date helpers

enum TimingFormat {
    static func parse(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":")
        var comps = DateComponents()
        comps.hour = parts.first.flatMap { Int($0) } ?? 7
        comps.minute = parts.dropFirst().first.flatMap { Int($0) } ?? 0
        return Calendar.autoupdatingCurrent.date(from: comps) ?? Date()
    }

    static func format(_ date: Date) -> String {
        let comps = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        return String(format: "%02d:%02d", h, m)
    }
}
