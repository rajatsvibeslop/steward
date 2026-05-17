import Foundation

// MARK: - Outkeep brand strings
//
// Single source of truth for the product's user-visible name and motto.
// Per brand brief: motto carries a trailing period — it's a statement, not a
// callout. Do NOT strip the period in display code.
//
// This file is the brand-token reference. Existing user-visible string literals
// throughout the app still say "Outkeep" inline (so the rename is searchable
// in greps and grep-on-pull-request); future copy should prefer `BrandStrings`
// for new surfaces so a future re-brand is a one-line change.
public enum BrandStrings {

    /// Product name as it appears to the user — home-screen icon label, nav
    /// titles, notification titles, audit-log persona, in-chat persona, etc.
    public static let appName = "Outkeep"

    /// Brand motto. Keep the period; it's a statement, not a tagline shout.
    /// Use Satoshi-Bold on display surfaces (splash, About).
    public static let motto = "Structure your life. Make better choices."
}
