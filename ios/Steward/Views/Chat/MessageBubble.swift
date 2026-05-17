//
//  MessageBubble.swift
//  Steward — Track E
//
//  Visual treatment per Designer §1.2. Three speakers must be visually
//  unambiguous: user (trailing, accent), coordinator (leading, secondary
//  background), domain (leading, tertiary background + leading accent stripe
//  in domain color).
//

import SwiftUI

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }
}

struct CoordinatorBubble: View {
    let text: String
    let showsStubChip: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .imageScale(.medium)
                .foregroundStyle(.tint)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Steward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showsStubChip {
                        StubChip()
                    }
                }
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 12)
    }
}

struct DomainBubble: View {
    let domainKey: String
    let displayName: String
    let text: String
    let showsStubChip: Bool

    private var color: Color { DomainColor.for(domain: domainKey) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle")
                .imageScale(.medium)
                .foregroundStyle(color)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(displayName) team")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showsStubChip {
                        StubChip()
                    }
                }
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(color)
                        .frame(width: 2)
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                }
                .background(
                    Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 12)
    }
}

struct HandoffIndicator: View {
    let domainKey: String
    let displayName: String

    private var color: Color { DomainColor.for(domain: domainKey) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(color)
            Text("Handing off to \(displayName) team…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

struct ThinkingBubble: View {
    let label: String
    let domainKey: String?

    private var color: Color {
        if let key = domainKey { return DomainColor.for(domain: key) }
        return .accentColor
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: domainKey == nil ? "sparkle" : "person.crop.circle")
                .foregroundStyle(color)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("⋯")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            }
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 12)
    }
}

struct SystemNoteRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.italic())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
    }
}

/// "STUB" chip per §1.10 / Designer note — shows when the response came from
/// `MockLLMSession`. We deliberately use a SF Symbol-free pill so the badge
/// is obvious without being aggressive.
struct StubChip: View {
    var body: some View {
        Text("STUB")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Color(.tertiarySystemFill),
                in: Capsule()
            )
    }
}
