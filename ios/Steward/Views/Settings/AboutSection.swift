//
//  AboutSection.swift
//  Steward — Track E
//
//  Designer §3.7. Foundation Models status dot, app version, export hook.
//

import SwiftUI

struct AboutSection: View {
    let backendKind: LLMBackendKind?

    var body: some View {
        Section("ABOUT") {
            HStack {
                Text("Foundation Models")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusLabel)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("App version")
                Spacer()
                Text(appVersion).foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        guard let kind = backendKind else { return .gray }
        switch kind {
        case .foundationModels: return .green
        case .mock: return .orange
        }
    }

    private var statusLabel: String {
        guard let kind = backendKind else { return "loading" }
        switch kind {
        case .foundationModels: return "available"
        case .mock(let reason):
            switch reason {
            case .sdkNotCompiledIn: return "stub (SDK absent)"
            case .modelNotAvailable: return "stub (unavailable)"
            case .modelNotReady: return "preparing"
            case .appleIntelligenceDisabled: return "off in Settings"
            case .deviceNotEligible: return "unsupported device"
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (build \(b))"
    }
}
