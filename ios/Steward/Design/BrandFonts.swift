import SwiftUI

// MARK: - Outkeep brand typography
//
// Display face: Satoshi (free under SIL OFL, bundled under Resources/Fonts/).
// Body face:    SF Pro — system default, no registration required.
//
// PostScript names below were verified directly from the bundled `.otf` files
// via fontTools (`name` table, nameID=6):
//
//     Satoshi-Light.otf   → "Satoshi-Light"
//     Satoshi-Regular.otf → "Satoshi-Regular"
//     Satoshi-Medium.otf  → "Satoshi-Medium"
//     Satoshi-Bold.otf    → "Satoshi-Bold"
//     Satoshi-Black.otf   → "Satoshi-Black"
//
// Per brand brief, Satoshi-Bold is the primary display weight (motto, large
// titles). Use the lighter weights sparingly for supporting display copy.
public enum SatoshiWeight {
    case light
    case regular
    case medium
    case bold
    case black

    /// PostScript name matched to the bundled OTF.
    public var postScriptName: String {
        switch self {
        case .light:   return "Satoshi-Light"
        case .regular: return "Satoshi-Regular"
        case .medium:  return "Satoshi-Medium"
        case .bold:    return "Satoshi-Bold"
        case .black:   return "Satoshi-Black"
        }
    }
}

public extension Font {
    /// Outkeep display face. Use for app name, motto, and large titles only;
    /// body copy stays on SF Pro for legibility and dynamic-type fidelity.
    static func satoshi(_ weight: SatoshiWeight, size: CGFloat) -> Font {
        Font.custom(weight.postScriptName, size: size)
    }
}
