import SwiftUI

// MARK: - Outkeep brand palette
//
// Canonical hex values live in /branding/palette.json. This file is the
// SwiftUI mirror — keep the two in sync if the brand is ever re-tuned.
//
// Usage rules (per brand brief, lighthouse-emblem voice "grounded, calm,
// protective"):
//   • Origin Bark / Deep Black — primary surface in dark mode; structural ink.
//   • Porcelain — primary surface in light mode; large neutral fields.
//   • Ulsan Gold — emblem & moments of warmth; the lighthouse glyph itself.
//   • Signal Flame — alerts / accent only; never as a flat field.
//
// All values are sRGB. SwiftUI's `Color(red:green:blue:)` initializer maps
// directly into the sRGB color space on iOS 17+, matching the hex codes
// extracted from the marketing renders.
extension Color {

    /// Origin Bark — dark warm brown. `#5C4627`.
    /// The grounding ink behind the gold lighthouse glyph in dark mode.
    static let originBark = Color(red: 0x5C / 255.0,
                                  green: 0x46 / 255.0,
                                  blue: 0x27 / 255.0)

    /// Ulsan Gold — warm muted gold. `#B4996C`.
    /// The lighthouse emblem color. Carries the brand's calm-protective tone.
    static let ulsanGold = Color(red: 0xB4 / 255.0,
                                 green: 0x99 / 255.0,
                                 blue: 0x6C / 255.0)

    /// Signal Flame — vivid warm orange. `#DC6E1F`.
    /// Reserved for alerts, recovery nudges, and rare emphasis moments.
    static let signalFlame = Color(red: 0xDC / 255.0,
                                   green: 0x6E / 255.0,
                                   blue: 0x1F / 255.0)

    /// Porcelain — near-white cream. `#FAFAFA`.
    /// Primary surface color in light mode; the calm field behind the glyph.
    static let porcelain = Color(red: 0xFA / 255.0,
                                 green: 0xFA / 255.0,
                                 blue: 0xFA / 255.0)

    /// Deep Black — soft true black. `#0A0A0A`.
    /// Primary surface color in dark mode; structural ground for the emblem.
    static let deepBlack = Color(red: 0x0A / 255.0,
                                 green: 0x0A / 255.0,
                                 blue: 0x0A / 255.0)
}
