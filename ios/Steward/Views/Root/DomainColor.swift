//
//  DomainColor.swift
//  Steward — Track E
//
//  Stable mapping from a `domain` identifier to a SwiftUI Color drawn from the
//  eight-color palette in `design/ui-specs.md` §1.2. Same domain string always
//  produces the same color, so the user's "Health team" looks the same on
//  Chat, Today, and Settings.
//
//  Hash is FNV-1a (32-bit) over the UTF-8 bytes so the mapping is platform-
//  independent and deterministic across launches. We deliberately do NOT use
//  Swift's default `String.hashValue` — that's seeded per launch.
//

import SwiftUI

enum DomainColor {
    /// The eight allowed colors per Designer §1.2.
    static let palette: [Color] = [
        .blue, .green, .orange, .purple,
        .pink, .teal, .indigo, .brown,
    ]

    /// Stable color for a given domain identifier.
    static func `for`(domain: String) -> Color {
        let h = fnv1aHash(domain)
        return palette[Int(h % UInt32(palette.count))]
    }

    /// FNV-1a 32-bit hash over the UTF-8 bytes of `s`. Public so tests can
    /// pin the mapping; pure, no global state.
    static func fnv1aHash(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return hash
    }
}
