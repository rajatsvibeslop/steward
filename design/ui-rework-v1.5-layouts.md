# Outkeep — UI Rework v1.5 Layouts (formerly Steward)

**Audience:** Implementation Pod (task #56).
**Status:** Source of truth for v1.5 visual layout and component shapes. Implementer drift gets graded against this file.
**Baseline tag:** `v0.9.6-sunday-morning` (v1 shipped under the prior product name "Steward").
**Rename:** the user-facing product name is **Outkeep** as of v1.5. Internal Swift module name, directory, and xcodeproj remain `Steward` — only user-visible strings and the home-screen display name change. Brand assets and font tokens ship via `ios/Steward/Design/BrandColors.swift` + `ios/Steward/Design/Typography.swift`.

**Companion docs (read first, this doc depends on both):**
- `/Users/rmehndir/dev/rajat/steward/design/ui-rework-v1.5-journey.md` (UXR — journeys, mental model, tile face, copy strings)
- `/Users/rmehndir/dev/rajat/steward/spec/ui-rework-v1.5-arch-impact.md` (Arch — data flow, filter rules, AgentLoop changes)

**Existing v1 visual language to inherit (do not relitigate):**
- `design/ui-specs.md` is the v1 spec. Bubble shapes, voice rationale, banned copy patterns — all carry over unless this doc explicitly overrides.
- `DomainColor.for(domain:)` is the stable per-domain color map. Same hash, same colors. (Brand pod re-tones the eight swatches inside the helper to harmonize with the Outkeep palette — `DomainColor.for(domain:)` is still the contract.)
- SF Symbols for icons. **Typography: Satoshi for display, SF Pro for body** (see §0.5). Dynamic type. Dark mode first-class.
- All copy verbatim — implement as string literals.

**What this doc covers:**
0.5. Brand kit (Outkeep) — palette tokens, typography tokens, light/dark mapping
0.6. Launch / splash screen — lighthouse emblem, wordmark, motto
1. `AgentGridView` (new root) — coordinator chat box, Up-Next strip, tile grid, gear
2. `TeamTile` — face spec, tap behavior, "+ Spawn a team" CTA variant
3. `DomainDetailView` — header, sub-tab bar, Chat sub-tab, Sheet sub-tab
4. `DeflectionChip` — verbatim copy and tap behavior
5. `GearOverlay` (Settings) — full-screen modal cover
6. Empty states
7. State diagrams
8. Surface migration table (implementer-actionable)
9. Copy block (verbatim, ready to paste)
10. Pushback / open calls

---

## 0.5 Brand kit — Outkeep

**Status:** authoritative for naming, typography, and color across the v1.5 surface. Brand tokens ship via `ios/Steward/Design/BrandColors.swift` + `ios/Steward/Design/Typography.swift` (Swift module name and file paths stay `Steward` — internal artifacts are not renamed).

### 0.5.1 User-facing name

The product is **Outkeep**. Every user-visible string that referenced "Steward" in v1 maps to "Outkeep" in v1.5. The coordinator agent's voice is unchanged — calm, low-bullshit, mercy-forward, non-moralizing — only the name changes. When users hear or read the product's name, it is always **"Outkeep"** verbatim, capital O.

**Banned:** "Outkeep app", "the Outkeep", "Steward" anywhere in user-facing copy.
**Permitted:** "Outkeep" as the speaker name in chat bubbles, as nav-bar title, as back-button label, as referenced in deflection chips and notification fallback strings, as the home-screen app display name.

The home-screen `CFBundleDisplayName` reads **"Outkeep"** even though the Xcode target is still `Steward`.

### 0.5.2 Motto (use only on splash and About)

> **Structure your life. Make better choices.**

Verbatim, including both periods. Never paraphrase, never elide the second clause, never split the sentence across more than two lines. Both clauses must appear together.

Surfaces that show the motto: splash screen (§0.6), Settings → ABOUT footer. Nowhere else.

### 0.5.3 Palette (exposed as `SwiftUI.Color` extensions)

| Token | Role | Used for |
|---|---|---|
| `Color.originBark` | Dark warm brown | Primary text in light mode; secondary surface tint in dark mode; chat-bubble primary label |
| `Color.ulsanGold` | Golden tan | Secondary accent; warm hierarchy; brief-preview "This morning" / time-of-day caption; section-header underline accents |
| `Color.signalFlame` | Warm orange | **Primary accent — replaces system blue everywhere.** CTAs, send button, mic recording state, focus stripes, brief-preview leading accent stripe, sparkle SF in coordinator chat box, "+ Spawn a team" affordances, deflection chip, splash emblem tint (light mode) |
| `Color.porcelain` | Cream | Light-mode canvas; dark-mode primary text; tile background in light mode; chat-bubble background for coordinator/domain replies |
| `Color.deepBlack` | Deep black | Dark-mode canvas; light-mode strongest text emphasis |

**Light/dark mode semantic role map** (use these adaptive aliases when rendering; brand pod's color extensions resolve the light/dark variant under `@Environment(\.colorScheme)`):

| Semantic role | Light mode | Dark mode |
|---|---|---|
| Page background (canvas) | `Color.porcelain` | `Color.deepBlack` |
| Elevated surface (tiles, coordinator chat box, brief preview, instrument cards, in-tile bubble backgrounds) | `Color.porcelain` with drop shadow (radius 4, opacity 0.05, y: 2) | `Color.deepBlack` with 1pt hairline border in `Color.originBark.opacity(0.18)` (shadows don't read in dark mode) |
| Tertiary surface (chips, disclosure cards inside Sheet sub-tab, Up-Next chip pills) | `Color.originBark.opacity(0.06)` over canvas | `Color.porcelain.opacity(0.06)` over canvas |
| Primary label | `Color.originBark` | `Color.porcelain` |
| Secondary label | `Color.originBark.opacity(0.6)` | `Color.porcelain.opacity(0.6)` |
| Tertiary label | `Color.originBark.opacity(0.4)` | `Color.porcelain.opacity(0.4)` |
| Primary accent (interactive) | `Color.signalFlame` | `Color.signalFlame` |
| Secondary accent (decorative warmth) | `Color.ulsanGold` | `Color.ulsanGold` |
| Separator / hairline | `Color.originBark.opacity(0.12)` | `Color.porcelain.opacity(0.12)` |
| Skeleton shimmer base | `Color.signalFlame.opacity(0.06)` | `Color.signalFlame.opacity(0.10)` |

**Implementation note for elevation:** in light mode tiles read elevated because of the drop shadow against the warmer `Color.porcelain` canvas — no separate "elevated background" color needed. In dark mode, drop shadows on near-black don't render, so the 1pt hairline carries the elevation. Implementer writes one `.elevatedSurface()` view modifier in the brand-kit package that branches on `colorScheme`; the rest of this doc just refers to "elevated surface."

**Domain colors:** the per-team accent stripe and tile-edge stripe continue to use the v1 `DomainColor.for(domain:)` helper. The brand pod is responsible for re-toning the eight swatches inside that helper so they harmonize with the Outkeep palette. **Do not** spec new domain colors in this doc; treat `DomainColor.for(domain:)` as the contract — when it ships v1.5-toned, all the per-domain UI inherits.

### 0.5.4 Typography (exposed as `SwiftUI.Font` extensions)

**Display face:** **Satoshi** (Indian Type Foundry). Access via `Font.satoshi(_ weight: Font.Weight, size: CGFloat)`.
**Body face:** **SF Pro** (system default). Access via the standard `Font.body`, `Font.caption`, etc.

When the implementer encounters a v1 reference like `.headline` / `.title2` / `.title3` in `ui-specs.md`, they substitute the v1.5 Satoshi-based equivalent from the table below. Body and caption styles continue to use system tokens.

| Role | Token | Use case |
|---|---|---|
| Display headline (large) | `Font.satoshi(.bold, size: 32)` | Splash wordmark; FM-unavailable takeover heading |
| Display headline (medium) | `Font.satoshi(.bold, size: 24)` | Empty-state primary line on zero-teams CTA tile (**"+ Spawn a team"**); empty-state headlines elsewhere |
| Display headline (small) | `Font.satoshi(.bold, size: 18)` | TeamTile name (was v1 `.headline`); section headers inside Sheet sub-tab; Settings section dividers if rebranded |
| Display value | `Font.satoshi(.medium, size: 24).monospacedDigit()` | TeamTile primary instrument value (was v1 `.title2.semibold.monospacedDigit`) |
| Display value (small) | `Font.satoshi(.medium, size: 18)` | Sheet sub-tab instrument section-header inline summary value (collapsed state) |
| Nav title | `Font.satoshi(.bold, size: 17)` | AgentGridView title **"Outkeep"**; DomainDetailView title **"{name} team"** |
| Display italic (motto) | `Font.satoshi(.medium, size: 16).italic()` | Splash motto only |
| Body | `Font.body` (SF Pro) | Chat bubble text, brief preview body, button labels, freshness fallback when prominence needed |
| Body emphasized | `Font.body.weight(.semibold)` | Primary CTA button labels |
| Caption | `Font.caption` (SF Pro) | Helper text under CTA tile, "From a notification" caption, brief preview "This morning" label |
| Caption (small) | `Font.caption2` (SF Pro) | Tile freshness subtext; separator labels |
| Inline monospaced digits | `Font.body.monospacedDigit()` | Up-Next chip time prefix |

### 0.5.5 Motif and voice

- **Lighthouse Emblem** is the brand mark. Source asset: `branding/gemini_gen_icon_light_mode.png`. Brand pod ships an asset-catalog entry `Image("OutkeepEmblem")` (the implementer references the asset name, never the raw file path). Used on: app icon, splash screen (§0.6), Settings → ABOUT row footer. **Never** inline in chat bubbles, tile faces, or as a generic decorative element.
- **Voice:** grounded, calm, protective. Already aligned with v1's tone-of-voice rules (`ui-specs.md` §4): no moralizing, no streak language, no "you should have", no "let's get back on track." The rebrand does not change voice rules — Outkeep speaks like Steward did, only with the new name.

---

## 0.6 Launch / splash screen

The first frame on cold launch. Covers the time between process start and Foundation Models availability check completing. Replaces v1's implicit "show Chat tab and hope FM warms before the user types" behavior.

### 0.6.1 When it appears

- Every cold launch.
- Foreground-from-background after >5 min suspended, if FM session needs cold-warm.
- **Not** shown on quick foreground returns (<5 min suspended, FM warm).

### 0.6.2 Layout

```
┌─────────────────────────────────────────────┐
│                                              │
│                                              │
│                                              │
│                                              │
│           [lighthouse emblem, 96pt]          │  ← Image("OutkeepEmblem"),
│                                              │     centered horizontally
│                                              │
│                Outkeep                       │  ← Font.satoshi(.bold, size: 32),
│                                              │     primary-label color
│                                              │
│    Structure your life. Make better choices. │  ← Font.satoshi(.medium, size: 16).italic(),
│                                              │     secondary-label color
│                                              │
│                                              │
│                  ◌                           │  ← optional status spinner;
│                                              │     hidden until FM init >800ms,
│                                              │     then fades in
│                                              │
└─────────────────────────────────────────────┘
```

### 0.6.3 Geometry

- Background: full-screen page canvas (`Color.porcelain` light / `Color.deepBlack` dark).
- All elements form one vertically-centered, horizontally-centered group.
- **Lighthouse emblem:** 96pt × 96pt.
  - Asset: `Image("OutkeepEmblem")`.
  - If the brand pod ships a **template-style** (single-color, tintable) emblem: tint with `Color.signalFlame` in light mode, `Color.ulsanGold` in dark mode.
  - If the brand pod ships a **full-color** emblem: render as-is, no tint.
  - Implementer confirms with brand pod which mode the asset is in. v1.5.0 default assumption: template-style.
- 24pt vertical gap.
- **Wordmark "Outkeep":** `Font.satoshi(.bold, size: 32)`, primary-label color (Origin Bark light / Porcelain dark). Single line, centered.
- 12pt vertical gap.
- **Motto "Structure your life. Make better choices.":** `Font.satoshi(.medium, size: 16).italic()`, secondary-label color (Origin Bark @ 0.6 light / Porcelain @ 0.7 dark). Center-aligned. Single line if width permits; otherwise wrap to two centered lines. The period after "choices" is part of the string.
- 64pt vertical gap.
- **Status spinner slot:** 24pt × 24pt. Default opacity 0. Fades in (200ms `.easeInOut`) only when FM init crosses 800ms wall-clock. Spinner is a small `Color.signalFlame`-tinted SwiftUI `ProgressView()` with `.scaleEffect(0.9)` so it sits visually at ~24pt without crowding.

### 0.6.4 Dismissal

- **Happy path (FM warm <600ms):** splash crossfades to `AgentGridView` over 250ms `.easeOut`.
- **Slow path (FM cold-warm 800ms–4s):** status spinner fades in. Splash holds until FM reports ready, then crossfades to `AgentGridView`.
- **Failure path (FM unavailable):** splash crossfades (200ms) to `FoundationModelsUnavailableView`:

  ```
  Foundation Models isn't available.

  Outkeep runs on Apple's on-device model.
  To use Outkeep, enable Apple Intelligence
  in Settings → Apple Intelligence & Siri.

  [ Open Settings ]   [ Try again ]
  ```

  - Heading: `Font.satoshi(.bold, size: 24)`, primary-label color.
  - Body paragraphs: `Font.body`, primary-label color, max-width 320pt.
  - **Open Settings:** `.borderedProminent` button, tint `Color.signalFlame`.
  - **Try again:** `.bordered` button, tint `Color.signalFlame`.

### 0.6.5 What the splash is NOT

- **Not onboarding.** Permissions and time preferences still run inside `AgentGridView`'s first-launch coordinator chat per `coordinator-empty-state-v2.md`.
- **Not marketing.** The motto is shown for ~1s on warm path, not as a dwell-on artifact. Brevity is the discipline; the motto sets tone, doesn't teach.
- **Not interactive.** No tap targets. Tapping during splash does nothing (deliberate — no accidental dismissal, no "Skip" button).
- **Not skippable.** It's short enough that skip would be friction.

### 0.6.6 Accessibility

- Apply `.accessibilityElement(children: .combine)` to the splash root container.
- Accessibility label: **"Outkeep. Structure your life. Make better choices. Loading."**
- VoiceOver reads the combined label once, then is silent until dismiss.
- Honor `Reduce Motion`: replace the 250ms crossfade with an instant cut (no fade).

### 0.6.7 Identity invariants

- Wordmark is always **"Outkeep"**, never "OutKeep" / "out-keep" / "OUTKEEP".
- Motto string and punctuation are immutable. No A/B variants in v1.5.0.
- Emblem proportions are not stretched; if the asset isn't square, pin to 96pt on the longer dimension and letterbox.
- No tagline or version string on the splash. No "by Anthropic" or similar.

---

## 1. AgentGridView (new root)

### 1.1 Replaces `RootTabView`

`RootTabView.swift` is deleted (per Arch Appendix A). New `RootView.swift` hosts a single primary surface: `AgentGridView`. No bottom tab bar.

`RootView` owns:
- A single long-lived `@StateObject ChatViewModel(thread: .coordinator)` so the coordinator chat persists across tile navigations (per Arch §5 "Coordinator VM lifetime quirk").
- A `NavigationPath` to push `DomainDetailView` on tile tap.
- A `@State` flag `isSettingsPresented: Bool` for the gear overlay.
- A `@State` flag `isCoordinatorChatExpanded: Bool` for the inline-vs-full-chat state of the coordinator chat box.

### 1.2 Screen layout

```
┌─────────────────────────────────────────────┐  ← safe area top
│  Outkeep                              ⚙      │  ← nav bar (large title hidden);
│                                              │     gear is a trailing toolbar button
├─────────────────────────────────────────────┤
│                                              │
│  ┌───────────────────────────────────────┐  │  ← coordinator chat box (collapsed)
│  │ ✦  Tell me what's on your mind, or    │  │     88pt height, 14pt corner radius,
│  │    hold the mic to talk.              │  │     .secondarySystemGroupedBackground,
│  └───────────────────────────────────────┘  │     16pt horizontal margin
│                                              │
│  ┌───────────────────────────────────────┐  │  ← Up-Next strip (hidden if empty)
│  │ 10:30 PM  Wind-down · 8:00 PM  Call Mom │ │     44pt height; horizontal chips
│  └───────────────────────────────────────┘  │
│                                              │
│  ┌──────────────┐  ┌──────────────┐         │  ← team grid (LazyVGrid)
│  │ Sleep team   │  │ Money team   │         │     2 cols on iPhone, 16pt h-margin,
│  │              │  │              │         │     12pt gutter; tile is ~173pt sq
│  │ 6.2h         │  │ $184         │         │     on a 390pt iPhone
│  │              │  │ left this wk │         │
│  │ logged 7h ago│  │ logged 1d ago│         │
│  └──────────────┘  └──────────────┘         │
│                                              │
│  ┌──────────────┐  ┌╌╌╌╌╌╌╌╌╌╌╌╌╌┐         │
│  │ Home team    │  │              │         │  ← "+ Spawn a team" CTA tile,
│  │              │  │      ✦       │         │     dashed border, always last
│  │ 2/3 today    │  │   + Spawn    │         │     position
│  │              │  │    a team    │         │
│  │ logged 3h ago│  │              │         │
│  └──────────────┘  └╌╌╌╌╌╌╌╌╌╌╌╌╌┘         │
│                                              │
│                                              │  ← scrolls if N teams overflow
└─────────────────────────────────────────────┘  ← safe area bottom
```

### 1.3 Nav bar

- `NavigationStack` root. Title: **"Outkeep"** as inline title (small, not large title) so it doesn't eat vertical space. Title typography: `Font.satoshi(.bold, size: 17)`, primary-label color.
- Leading: nothing.
- Trailing: SF `gearshape` (single icon, not `gearshape.fill`). Tap → presents `GearOverlay` as full-screen modal cover (see §5). 22pt tap region; `Color.signalFlame` foreground.
- Background: matches scroll content; no `Material` blur. Page canvas color (`Color.porcelain` light / `Color.deepBlack` dark).

### 1.4 Coordinator chat box (collapsed)

The most important component on this screen. It must read as "tap to talk to Outkeep" at a glance without looking like a tile.

**Geometry:**
- Width: full minus 16pt left/right safe-area margins.
- Height: **88pt** in normal placeholder state. **Grows to 132pt** when showing the morning-brief preview (see §1.4.3).
- Corner radius: 14pt.
- Background: **elevated surface** per §0.5.3 (Porcelain w/ drop shadow in light; Deep Black w/ hairline in dark).
- Inner padding: 14pt vertical, 14pt leading, 14pt trailing.

**Left affordance (always present):**
- 22pt `sparkle` SF Symbol in `Color.signalFlame`, vertically centered, 10pt right margin to the text.
- **Pushback on UXR §5.1 ASCII:** UXR's mockup shows `🎙` on the left. I'm specifying **sparkle** instead. Rationale: this matches the v1 coordinator identity (the "I'm Outkeep" first-launch greeting uses `sparkle`, carried over from v1's `ui-specs.md` §1.7), keeps the mic anchored to the input bar inside the expanded chat (where hold-to-talk actually lives), and avoids the implication that tapping the chat box starts recording instead of opening chat. The mic only ever appears inside the expanded `ChatInputBar`.

**Placeholder text (normal state):**
- Verbatim: **"Tell me what's on your mind, or hold the mic to talk."**
- Typography: `Font.body` (SF Pro), secondary-label color, 1 line, truncate tail.
- Vertically centered within the 88pt box.

**Tap target:** entire box is one tap target (`.contentShape(Rectangle())` over the full frame). Tapping pushes a `CoordinatorChatView` onto the `NavigationStack` (full-screen chat surface, reuses v1's `ChatView` body with the long-lived `ChatViewModel(thread: .coordinator)`).

**Long-press:** no behavior in v1.5.0.

#### 1.4.1 Visual states

1. **Idle (default).** Placeholder copy as above. Elevated surface per §0.5. No badge.
2. **Brief preview (07:00–12:59 local on a day where `latestBrief.acknowledged == false` AND `latestBrief.generatedAt > now - 6h`).** See §1.4.3 for full spec.
3. **Coordinator turn in flight** (rare — the user expanded chat and a turn is running, then backed out before it returned): show a 2pt shimmering `Color.signalFlame` stripe at the top edge of the box only; placeholder copy unchanged. Tapping still re-expands chat. Removed when turn completes.
4. **Foundation Models unavailable.** Box is greyed out (tertiary-surface background per §0.5; tertiary-label foreground). Placeholder swaps to **"Outkeep is offline — tap for details."** Tap pushes a static `FoundationModelsUnavailableView` mirroring §0.6.4's failure-path content.

#### 1.4.2 Coordinator chat box is NOT the input bar

Do not allow text input directly in the collapsed box. The collapsed box is a button. Text input happens in the expanded `CoordinatorChatView`. This is deliberate: it preserves single-handed reachability (no keyboard popping under your thumb when you're scanning the grid) and avoids the IA mistake of treating the landing as a chat-first surface — it's a glance-first surface where chat is one tap away.

#### 1.4.3 Brief-preview state (07:00 morning brief surface)

Per team-lead lock-in and UXR §3.4: morning brief is previewed in this box.

**Geometry when brief preview is showing:**
- Height grows from 88pt to **132pt**.
- Inner content reorders:
  - 2pt-wide accent stripe pinned to the leading inner edge, height = full inner height minus 4pt top/bottom. Color: `Color.signalFlame`.
  - Sparkle SF symbol replaced by **nothing** (the accent stripe carries the visual identity); content begins after the stripe with 12pt leading padding.
  - Top row: small `Font.caption` label **"This morning"** (or "This afternoon" / "This evening" / "Tonight" matching `CoordinatorEmptyStateCopy.greeting(forLocalHour:)` time-of-day variant — same Swift logic), foreground `Color.ulsanGold` (warm hierarchy token; differentiates the brief preview from generic placeholder).
  - Body: 2-line italic excerpt of the brief, `Font.body.italic()`, primary-label color. Format: **"{brief first sentence, ≤80 chars}. Tap to read the full brief."** Truncate the first sentence at 80 chars with "…" if needed.
  - Trailing edge of top row: small `×` button (SF `xmark.circle.fill`, 18pt, secondary-label color). Tapping it dismisses the preview locally (writes `briefs.acknowledged = true`) and reverts box to idle.

**State machine for the preview:**
- Show when: `latestBrief.generatedAt > now - 6h` AND `latestBrief.acknowledged == false` AND `latestBrief.generatedAt < now` (i.e., not future-dated).
- Hide when: any of the above is false, OR user has tapped × to dismiss locally, OR user has opened the full coordinator chat (reading = acknowledging).
- The `latestBrief.acknowledged` write happens on tap-into-chat OR explicit ×.

**Tap behavior in brief-preview state:**
- Tap anywhere in the box → push `CoordinatorChatView` AND scroll its message list to the brief bubble (which lives in coordinator chat as the most recent assistant bubble). This is one tap, one action; the preview is the same data shown in compact form.

### 1.5 Up-Next strip

Per UXR §5.3, locked at "below coordinator chat box, above the tile grid."

**Geometry:**
- Width: full minus 16pt left/right margins.
- Height: **44pt** when populated. **Removed from layout entirely** (zero height, no placeholder) when there's nothing in the next 12h.
- Background: clear. No card chrome — chips are the visual elements.
- 12pt vertical margin above and below.

**Content:**
- Up to **2 chips**, horizontal row, 8pt gutter.
- If overflow (>2 items in window): show top 2; do not paginate, do not show "more." The user can dig into Settings → Activity or coordinator chat for the rest. This is a glance surface.
- Source (from Arch §1 filter rules, restated): `commitments WHERE status='active' AND due_at <= now + 12h` UNION `notifications WHERE delivered_at IS NULL AND scheduled_for <= now + 12h`, sorted ascending by time.

**Chip shape:**
- Rounded capsule, corner radius 22pt (half height), 12pt horizontal padding, 8pt vertical.
- Background: tertiary-surface token per §0.5 (Origin Bark @ 0.06 light / Porcelain @ 0.06 dark).
- Foreground: primary-label color.
- Time prefix uses `Font.body.monospacedDigit()`; label uses `Font.body`.
- Format: **"{HH:mm} {short label}"** — e.g., **"10:30 PM  Wind-down"**, **"8:00 PM  Call Mom"**.
- Time uses 12-hour AM/PM, matching v1's `ui-specs.md` §4 time format.
- Label truncates tail to fit 24-char total budget (incl. time).
- No domain color stripe on chips — they're cross-domain by nature. Optional 4pt leading dot in `DomainColor.for(item.domain)` if implementer wants the bridge; not required and not specified as default. Default: no dot.

**Chip tap behavior:**
- Commitment chip → opens existing v1 commitment detail sheet (unchanged; reused).
- Notification chip with `context.domain == nil` → opens full `CoordinatorChatView` and injects `context.suggestedPrompt` (same handler as notification deep-link).
- Notification chip with `context.domain != nil` → opens `DomainDetailView(domain:)`, Chat sub-tab, with `suggestedPrompt` injected as a coordinator-initiated bubble in that tile's chat (same handler as notification deep-link; see §7 state diagrams).

**Chip dismiss:**
- No swipe-to-dismiss. The strip is read-only; user can only complete commitments or let notifications fire.

### 1.6 Team tile grid

`LazyVGrid` below the Up-Next strip. Always shows the "+ Spawn a team" tile as the last position.

**Grid columns:**
- iPhone (width <600pt): **2 columns**, 12pt gutter.
- iPad / wide (width ≥600pt, ≥900pt): **3 columns**.
- iPad landscape (width ≥1100pt): **4 columns**.
- **v1.5.0 ships iPhone-only per UXR §6.** Wider widths get a sensible default but are not first-class until v1.6. Implement using `LazyVGrid(columns: adaptiveColumns(minimum: 160, maximum: 200))` so it scales gracefully without explicit breakpoint code.

**Tile geometry:**
- Aspect ratio: square (1:1).
- On standard 390pt iPhone: tile width ≈ (390 − 16 − 16 − 12) / 2 = 173pt; height = 173pt.
- Minimum tap target satisfied at any column count down to 160pt × 160pt.

**Tile gutter and outer margins:**
- Outer margin (grid to screen edges): 16pt left/right.
- Gutter between tiles: 12pt horizontal, 12pt vertical.

**Scroll behavior:**
- Whole landing is a single `ScrollView` containing the chat box, Up-Next strip, and `LazyVGrid` in a `VStack`. Coordinator chat box and Up-Next strip scroll with the grid (they are not pinned headers). This is deliberate: at 20 teams, the user pulls up to see more tiles and the chat box scrolls out of view, which is fine because it remains one tap away once they pull back down.
- No pull-to-refresh on landing. Tile faces refresh reactively from `ObservableObject` view models; no manual refresh affordance.
- ScrollView background: page canvas (`Color.porcelain` light / `Color.deepBlack` dark) per §0.5.

**Tile ordering (v1.5.0):**
- `domains WHERE archived_at IS NULL ORDER BY created_at ASC` — stable creation order.
- "+ Spawn a team" tile always last position.
- No drag-to-reorder (deferred to v1.5.x per UXR §6).

**Tile count scaling — what happens at 1 / 4 / 20 teams:**

| Teams | Grid rows | Notes |
|---|---|---|
| 0 teams | 1 row, 1 column visible (spawn tile alone, full-width treatment — see §6.1) | Empty-state behavior. Spawn tile takes the full row width to read as a CTA, not a half-tile orphan. |
| 1 team | 1 row, 2 tiles (Team + Spawn) | Normal half-width tiles. |
| 4 teams | 2 rows, 5 tiles total (4 teams + Spawn alone on row 3) | Spawn tile on row 3 takes half-width as normal — does NOT expand to full-width when "+ Spawn" is alone on its row. Visually distinct via dashed border (see §2.3) so it doesn't read as a missing partner. |
| 20 teams | 10 rows, 21 tiles | Scrolls. Lazy-loaded. |

Edge case: when team count is **odd** (so spawn tile would be alone on its row), spawn stays as a half-width tile. No special "fill" treatment.

### 1.7 Gear icon (toolbar)

- Trailing toolbar item on the `AgentGridView`'s nav bar.
- SF `gearshape` (not `.fill`), 22pt regular weight, system blue accent.
- Tap → presents `GearOverlay` (full-screen modal cover with internal `NavigationStack`). See §5.
- No long-press behavior in v1.5.0.

### 1.8 Notification banner overlay on landing

When a foreground notification arrives while the user is on `AgentGridView`, the system banner handles it (`UNUserNotificationCenter` delegate). No custom in-app banner in v1.5.0.

---

## 2. TeamTile

`TeamTileView` is a single `View` parameterized by the team's `domain: String` and its primary instrument summary.

### 2.1 Anatomy

Three elements only (per UXR §2.2 lock-in). Plus an optional unread dot.

```
┌──────────────────────────┐
│ Sleep team        ●      │  ← team name (top) + optional unread dot (top-right)
│                          │
│                          │
│      6.2h                │  ← primary instrument value (center, large)
│                          │
│                          │
│ logged 7h ago            │  ← freshness subtext (bottom)
└──────────────────────────┘
```

**Tile container:**
- `RoundedRectangle(cornerRadius: 14)` background: **elevated surface** per §0.5.3 (Porcelain w/ drop shadow in light; Deep Black w/ hairline in dark).
- 2pt-wide leading accent stripe in `DomainColor.for(domain)` — matches v1 chat domain-bubble accent. Stripe runs full inner height, inset 8pt from top/bottom (looks like a tab edge, not a full-height border).
- Inner padding: 14pt all sides.
- Drop-shadow params for light mode: `radius: 4, x: 0, y: 2, opacity: 0.05`. Dark mode: no shadow (hairline carries elevation per §0.5).

### 2.2 Element specs

**Team name (top):**
- Format: **"{display_name} team"** — verbatim from `domains.display_name + " team"`. Implementer should NOT hardcode the " team" suffix in the Swift string — the domain agent's display name is "Sleep", "Money", etc., and the UI appends " team" once.
- Typography: `Font.satoshi(.bold, size: 18)`, primary-label color (Origin Bark light / Porcelain dark).
- Single line, truncate tail at "{Domain} t…" if domain name is exceptionally long.
- Top-aligned, 0pt top inset within the inner padding.

**Primary instrument value (center):**
- Source: per Arch §1, the team's most-recently-updated instrument's `state_json` → human-readable value formatted by the existing `InstrumentDisplay` (v1's instrument-card value formatter).
- Typography: `Font.satoshi(.medium, size: 24).monospacedDigit()` so "6.2h" and "12.4h" don't jiggle on update.
- Foreground: primary-label color (Origin Bark light / Porcelain dark).
- Single line, truncate middle (`.middle`) — for "$184 left this week", we'd rather see "$184 left…wk" than "$184 left this…" so the unit stays visible.
- Vertically centered within the tile's content area.
- 2-line variant for instruments where the value needs more room (e.g., bounded_budget "left this week" subtext): primary value on line 1 (e.g., **"$184"**, .title2), secondary unit on line 2 (e.g., **"left this week"**, .caption, .secondaryLabel). Implementer chooses the variant from a per-kind formatter — same one used in v1's `InstrumentCard`. Mapping:

  | kind | Tile primary value | Tile second line (if any) |
  |---|---|---|
  | `running_accumulator` | today's total + unit (e.g., **"42 min"**) | — |
  | `bounded_budget` | **"$184"** | **"left this week"** |
  | `rolling_average` | current rolling avg + unit (e.g., **"6.2h"**) | — |
  | `countdown_commitment` | **"2 / 3"** | — |
  | `weekly_evidence_log` | **"{N} this week"** | — |
  | `checklist` | **"{N} / {total}"** | **"today"** |
  | `bounded_window` | **"{compliance_pct}%"** | — |

  No second line for kinds not listed above. The second line is `Font.caption` / secondary-label color and 8pt above the freshness subtext.

**Freshness subtext (bottom):**
- Format examples: **"logged 7h ago"** / **"logged 3d ago"** / **"not yet today"** / **"no logs yet"**.
- Typography: `Font.caption2` (SF Pro, 11pt), secondary-label color.
- Single line, truncate tail.
- Bottom-aligned, 0pt bottom inset within the inner padding.
- **Banned phrasings:** "missed", "overdue", "X days behind", anything implying lapse. Lapses are ordinary per spec §15. The formatter is a Swift helper `FreshnessFormatter.format(lastLoggedAt:now:)` that maps elapsed time → one of: "logged Nm ago" / "logged Nh ago" / "logged Nd ago" / "logged Nw ago" / "not yet today" (if elapsed > 24h) / "no logs yet" (if last_logged_at is nil). The "not yet today" copy is the most lapse-adjacent string — and it's intentionally framed as forward-looking ("not yet" implies "still could") rather than backward-looking ("missed").

**Optional unread dot (top-right):**
- Per UXR §2.2 and §5.4: lights up when "the team's agent did something the user hasn't seen — a new proposal in the team chat, a completed scheduled task with a note, a CSV mirror conflict."
- **NEVER lights up for "you missed N days."**
- Visual: 8pt-diameter circle, fill `Color.signalFlame`, with 1pt page-canvas outer halo for contrast.
- Position: 6pt from top edge, 6pt from trailing edge of tile inner content area (i.e., 20pt from top-right corner of the tile container).
- Computation source: per Arch §10 defer to v1.6 — "v1.5 can skip the badge entirely and just show last-event-timestamp instead." For v1.5.0 the unread dot is **NOT shown.** Implementer leaves the slot in the layout (don't reflow the name when adding it back) but the dot is `opacity: 0` in v1.5.0. Wire visibility behind a feature flag so v1.6 can flip it on without a layout change.

### 2.3 "+ Spawn a team" CTA tile variant

Same `TeamTileView` component, parameterized by a different model. Distinctly different look so it doesn't read as a real team.

```
┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐
│                            │
│           ✦                │  ← sparkle SF, 28pt, accent color
│                            │
│      + Spawn a team        │  ← .headline, accent color
│                            │
│   This is where your       │  ← .caption, secondaryLabel
│   teams live. Tap to start.│
│                            │
└╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘
```

**Container:**
- Same size as regular tiles.
- Background: page canvas (`Color.porcelain` light / `Color.deepBlack` dark) — reads as "empty slot" against the elevated real-team tiles.
- Border: 1pt dashed in `Color.signalFlame.opacity(0.4)`, corner radius 14pt, dash pattern `[4, 4]`.
- No drop shadow.
- No accent stripe on the leading edge.

**Inner content:**
- Sparkle SF Symbol, 28pt regular weight, `Color.signalFlame`, top-centered with 24pt top inset.
- Label **"+ Spawn a team"** in `Font.satoshi(.bold, size: 18)`, `Color.signalFlame`. 12pt below sparkle.
- Subtext **"This is where your teams live. Tap to start."** in `Font.caption`, secondary-label color, 2 lines centered. 8pt below label.
- All elements centered horizontally.

**Tap behavior:**
- Pushes `CoordinatorChatView` onto the nav stack (same as tapping the coordinator chat box).
- Injects a pre-seeded coordinator bubble into the chat (per UXR §2.5): **"Want to add a new team — what would you like me to help carry? Name and tone are up to you; I'll propose a starting shape."**
- Does NOT auto-send a user message. The user types or holds the mic; coordinator runs Branch B from B1 onward.

**When empty-state (0 teams):** see §6.1 for the full-width variant treatment.

### 2.4 Tile tap behavior (regular team tile)

- Single tap → pushes `DomainDetailView(domain: domain)` onto the nav stack.
- The push animation is the standard iOS NavigationStack horizontal slide.
- Pre-load: the tile owns a small `DomainTileViewModel` that pre-fetches the primary instrument summary and last_logged_at when the view appears in the LazyVGrid. The push into detail view reuses this VM's already-fetched state so the detail view's tile-header chrome renders instantly.

**No long-press context menu in v1.5.0.** Rename, archive, change tone — all live behind the per-team gear icon inside `DomainDetailView` (see §3.2). Reasoning: long-press menus on tiles in a thumbable grid invite accidental triggers and surface advanced actions where the user is in glance mode.

### 2.5 Tile loading and error states

- **Initial load (DB query in flight):** show the tile skeleton — name visible, value position shows a 28pt × 64pt shimmer pill (base `Color.signalFlame.opacity(0.06)` light / 0.10 dark, see §0.5 skeleton token), freshness shows a 16pt × 80pt shimmer pill. No spinner. Skeleton clears as soon as the VM has data.
- **Tile failed to load primary instrument:** name visible, value shows **"—"** (em-dash), freshness shows **"couldn't read this tile"** in `Font.caption2`, secondary-label color. Tile is still tappable; opening detail view will retry.
- **Tile has zero instruments yet:** value shows **"No tracks yet"** (`Font.body`, secondary-label color), freshness shows **"tap to add one"** (`Font.caption2`, `Color.signalFlame`). Tile is tappable; tap opens detail view, which routes the user via Sheet tab's empty state (see §6.3).

---

## 3. DomainDetailView

### 3.1 Screen layout

```
┌─────────────────────────────────────────────┐
│  ← Sleep team                         ⚙      │  ← nav bar; back chevron leading,
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │     team gear trailing
├─────────────────────────────────────────────┤
│  [ Chat ]  [ Sheet ]                         │  ← sub-tab segmented picker
├─────────────────────────────────────────────┤
│                                              │
│                                              │
│      (sub-tab body — Chat or Sheet)         │
│                                              │
│                                              │
│                                              │
├─────────────────────────────────────────────┤
│  [ ✦  Type or hold the mic to talk.   ] [→] │  ← input bar (Chat only;
└─────────────────────────────────────────────┘     hidden on Sheet)
```

### 3.2 Header

- Nav bar (inline title style, not large title). Title typography: `Font.satoshi(.bold, size: 17)`.
- **Leading:** standard back chevron (`NavigationStack` default) labeled **"Outkeep"** as the back-button text. Tapping pops to landing.
- **Title:** **"{display_name} team"** — same string format as the tile.
- **Trailing:** SF `gearshape` in `Color.signalFlame` (per-team gear). Tap → presents `TeamSettingsView` as a `.sheet` (not full-screen modal, because per-team settings are shallow: rename, change tone, archive).
- **Team color stripe:** a 3pt-tall horizontal stripe directly beneath the nav bar, full width, color `DomainColor.for(domain)`. This is the strongest in-app signal that the user has switched contexts to this team's room. The stripe persists across both Chat and Sheet sub-tabs.

### 3.3 Sub-tab bar

**Component:** SwiftUI `Picker` with `.pickerStyle(.segmented)`, pinned just below the team color stripe.

**Critical clarification (pushback on UXR §5.2 ASCII):** UXR's mockup `[ Chat ] [ Sheet ]` reads like a custom tab control. Implementer **MUST use a segmented `Picker`**, not a custom UISegmentedControl, not a nested `TabView`. Nested TabViews create gesture conflicts with the back chevron and we just removed the parent TabView for that exact reason. Segmented Picker is the iOS-native pattern and renders correctly with Dynamic Type.

**Picker config:**
- Two options: **"Chat"** and **"Sheet"** (verbatim labels). Label font: `Font.body.weight(.semibold)` (system default for segmented Picker; no override needed).
- Tint: `Color.signalFlame` (apply via `.tint(.signalFlame)` on the Picker).
- Selection bound to a `@State enum DomainSubTab { case chat, sheet }` on the `DomainDetailView`.
- Default selection: **`.chat`** on cold-open per UXR §6 ("v1.5.0 always defaults team tile to Chat sub-tab on cold open"). Per-tile last-selected persistence is a v1.5.x add — do NOT implement in v1.5.0.
- Notification deep-link force-selects `.chat` regardless of last-selected (per UXR §3.3).

**Geometry:**
- Width: full minus 16pt left/right margins.
- 8pt top margin from the color stripe.
- 12pt bottom margin to the sub-tab body.
- Standard segmented control height (~32pt).

**Switching sub-tabs:**
- Preserves the Chat draft if any (the `ChatInputBar`'s text field state lives on the `ChatViewModel`, not the segmented picker selection).
- Switching to Sheet hides the input bar.
- Switching back to Chat shows the input bar; if a draft exists, it's still there.

### 3.4 Chat sub-tab body

This is the per-team direct-to-domain chat per Arch §2.

**Reused component:** the existing v1 `ChatView` body (the scrolling message list + input bar from `ui-specs.md` §1.1). Constructed with a `@StateObject ChatViewModel(thread: .domain(DomainID(domain)))`. The VM lifecycle is bound to `DomainDetailView` — dismissing the detail view discards the VM, but its `messages` state is reloaded from `events` filtered by `domain = ?` when the view re-appears, so nothing is lost.

**Message bubble styles inside tile chat (delta from v1):**
- **User bubbles:** unchanged (trailing-aligned, accent blue, white text).
- **Domain agent bubbles:** reuse the existing `DomainBubble` style (leading accent stripe in `DomainColor.for(domain)`, "{Domain} team" label above first bubble in a run). Same component as v1.
- **Coordinator bubbles:** **never appear inside tile chat.** The coordinator never speaks in a tile per UXR §2.7. If a handoff happens elsewhere and writes a coordinator/agent reply with `domain != domain`, it's filtered out by the VM's query.
- **Coordinator-initiated bubbles from notification deep-link:** rendered as a `DomainBubble` styled for the team (since the suggested-prompt is contextually about this team). The bubble is `actor='coordinator', domain=<domain>` — yes, an exception to "coordinator never speaks in tile" — and it's clearly framed as a one-shot injection: **"Outkeep says: {suggestedPrompt}"** with a small `Font.caption` secondary-label line **"From a notification"** above the bubble. The user can reply normally; their reply talks to the team agent directly.

  Pushback note: Arch §2's table says tile chat is `WHERE domain = ? AND kind = 'chat_turn'` for messages, which would include this injected coordinator bubble (kind=chat_turn, domain=<team>, actor=coordinator). That's consistent. We're not violating the IA — the coordinator's notification-context appearance in tile chat is a documented, contained exception, not a general handoff lane.

**Input bar:**
- Reuse `ChatInputBar` from v1's `Views/Chat/ChatInputBar.swift`. Same behavior.
- Placeholder copy (verbatim): **"Type or hold the mic to talk."** — note: shorter than the coordinator chat box placeholder, matches what's already in v1's input-bar placeholder pool.
- Mic = hold-to-talk per v1 spec §1.6.
- When a turn is in flight: greyed, placeholder **"{Domain} team is working…"** — substitute the domain display name.

**Out-of-scope deflection (DeflectionChip):**
- When the domain agent emits a deflection reply (recognizing an out-of-scope question per UXR §4.5), the reply renders as a normal `DomainBubble` containing the verbatim deflection sentence. Immediately below the bubble (8pt vertical gutter, leading-aligned matching the bubble), a `DeflectionChip` appears. See §4 for chip spec.

### 3.5 Sheet sub-tab body

Per UXR §2.4 and Arch §1: all instruments-as-grids, stacked, with an "All events" disclosure at the bottom.

**Screen layout:**

```
┌─────────────────────────────────────────────┐
│  [ Chat ]  [ Sheet ]                         │
├─────────────────────────────────────────────┤
│                                              │
│  Last updated 7h ago        [ + Add a track ]│  ← header strip
│                                              │
│  ┌─────────────────────────────────────────┐│
│  │ ▾ Sleep · 7-day rolling average         ││  ← instrument section
│  ├─────────────────────────────────────────┤│
│  │ (existing v1 §12.1 in-app spreadsheet   ││
│  │  grid: header row, data rows, computed  ││
│  │  values footer)                          ││
│  └─────────────────────────────────────────┘│
│                                              │
│  ┌─────────────────────────────────────────┐│
│  │ ▸ Weight · rolling average               ││  ← collapsed (≥4 instruments)
│  └─────────────────────────────────────────┘│
│                                              │
│  ┌─────────────────────────────────────────┐│
│  │ ▸ All events                             ││  ← collapsed disclosure
│  └─────────────────────────────────────────┘│
│                                              │
└─────────────────────────────────────────────┘
```

**Header strip:**
- Background: clear.
- 16pt horizontal margin, 12pt vertical.
- Left: **"Last updated {relative timestamp}"** — `.caption`, `.secondaryLabel`. Source: max `events.created_at WHERE domain = ? AND kind = 'instrument_update'`. Format: same `FreshnessFormatter` style ("7h ago", "3d ago"); never "missed" or "overdue."
- Right: **"+ Add a track"** button, `.borderedTinted` style with `.tint(.signalFlame)`, `Font.caption` font. Tap behavior: pushes `DomainDetailView`'s Chat sub-tab AND injects a coordinator-style bubble (but it's the team agent speaking) **"Want to add a track here? Tell me what you'd like me to keep an eye on."** Does NOT auto-send. Same low-ceremony "add via chat" pattern as spawning a new team.

  Implementation note: "+ Add a track" lives on the team agent thread, NOT coordinator. The team agent runs the spawn-instrument sub-conversation (a smaller variant of Branch B Step B3 — propose ONE instrument, three chips Yes/Different/Skip). This is consistent with the "spawn always through coordinator" rule because we're adding an *instrument*, not a *team* — instruments are within-team affordances, and the team agent owns them.

**Instrument sections (one per instrument, in order of most-recently-updated):**

- Each section is a `RoundedRectangle(cornerRadius: 12)` `.secondarySystemGroupedBackground` container with 14pt inner padding.
- 12pt vertical gutter between sections, 16pt horizontal margin to screen edges.
- **Section header (always visible):**
  - Disclosure chevron (`chevron.down` expanded, `chevron.right` collapsed) leading.
  - Instrument name + ` · ` + kind label — e.g., **"Sleep · 7-day rolling average"**. Name is `.headline`, kind label is `.caption`, `.secondaryLabel`, inline after the dot.
  - When collapsed and ≥4 instruments: append a one-line summary on the right edge — `.caption.monospaced`, the primary value (e.g., **"6.2h"**). Single line, truncate tail.
- **Section body (when expanded):**
  - Renders the existing spec §12.1 in-app spreadsheet grid component (the same one v1 used inside `InstrumentGridView`). Drop the back-button chrome — we're inside a tab body, not pushed.
  - Header row from `definition_json`, data rows from `state_json + events`, computed-values footer (rolling aggregates).
  - Inline tap-to-edit on cells still works (writes `manual_correction` event, instrument updater ingests it). Unchanged from v1.
- **Default expand/collapse state:**
  - ≤3 instruments in the team: all expanded by default.
  - ≥4 instruments: first expanded (most recently updated), rest collapsed.
- **No drag-to-reorder** in v1.5.0. Sections stay in most-recently-updated order, recomputed on view appear.

**"All events" disclosure (always at the bottom of the Sheet body):**
- Section header (matching style): **"▸ All events"** — `.headline`, `.label`. No counter.
- Collapsed by default. Expand → reverse-chronological list of events for this domain.
- Query (per Arch §1 filter rules, restated): `WHERE domain = ? AND kind NOT IN ('chat_turn', 'agent_reply') ORDER BY created_at DESC LIMIT 50`.
- Each row: `HH:mm · {kind_human_label}` on line 1 (`.body`), one-line `text` summary on line 2 (`.caption`, `.secondaryLabel`). 12pt vertical padding, 1pt separator between rows.
- Tap an event row → push a small `EventDetailSheet` showing actor, full text, full payload_json (pretty-printed), reasoning. Reuse v1's audit-log row detail pattern.
- "Show 50 more" button at bottom if results truncated.

**Sheet sub-tab scrolling:**
- Whole body is a single `ScrollView`. Header strip scrolls with content. Sub-tab picker (above) stays pinned via SwiftUI's normal layout — it's outside the ScrollView.
- No pull-to-refresh on Sheet (state is reactive).

### 3.6 Team-scoped gear → `TeamSettingsView`

Per UXR §4.4: "Per-team settings (rename, change tone, archive) live behind a secondary gear icon inside the team tile header, NOT in global Settings."

`TeamSettingsView` is presented as a `.sheet` (not full-screen modal) from `DomainDetailView`'s trailing toolbar item. Content (form-style):

```
┌─────────────────────────────────────────────┐
│  Sleep team                          Done    │
├─────────────────────────────────────────────┤
│                                              │
│  NAME                                        │
│  ────────────────────────────────────────    │
│  [ Sleep                                  ]  │  ← text field
│                                              │
│  TONE                                        │
│  ────────────────────────────────────────    │
│  ● Stay gentle. Just track. (default)        │
│  ○ Push back a little when I'm slipping.     │
│  ○ Push hard. Call me out when needed.       │
│                                              │
│  See exact instructions  ▸                   │  ← expands to show role_prompt
│                                              │
│  ACTIONS                                     │
│  ────────────────────────────────────────    │
│  Archive this team                           │  ← red destructive
│                                              │
└─────────────────────────────────────────────┘
```

- **Name:** inline `TextField`. Save on blur or on Done. Writes via `domain.update` (rename).
- **Tone:** three radio buttons matching the `RolePromptTemplates` from `coordinator-empty-state-v2.md` §7.1–7.3 verbatim. Selecting a tone overwrites `role_prompt` with the corresponding template. Currently-selected tone is computed by string-matching the stored `role_prompt` against the three templates; if no match (user edited freeform), show **"Custom"** as the selected option and let them pick a preset to overwrite, with a confirmation alert: **"Replace your edited instructions with this preset?"** Buttons: **Replace** / **Cancel**.
- **See exact instructions:** disclosure expands to show the literal `role_prompt` in a multi-line `TextEditor`, freely editable. Same component as v1's `DomainDetailView` role-prompt editor.
- **Archive:** red `.destructive` button. Confirmation alert (verbatim from v1): **"Archive {display_name} team? Its instruments stop updating. You can still see history."** Buttons: **Archive** / **Cancel**.

The "Done" button (top-right) dismisses the sheet. All edits commit on blur or Done.

---

## 4. DeflectionChip

A small inline UI affordance that appears beneath a domain agent's out-of-scope deflection bubble.

### 4.1 Trigger

- Domain agent in tile chat replies with the verbatim deflection sentence (per UXR §4.5 and `RolePromptTemplates.swift`'s out-of-scope deflection clause):

  > **"That's a {guessed_domain} thing — I only know about {your_domain_name}. Want me to ping the {guessed_domain} team, or paste it in the Outkeep chat?"**

- The agent's reply is a normal `chat_turn` event. The deflection is detected by the UI looking at the event's payload — Arch §10 specifies a `payload_json` flag `is_deflection: true` + `guessed_domain: string` + the user's original message text preserved as `original_user_message: string`. The `RolePromptTemplates` template instructs the LLM to emit these fields when it deflects; the UI keys off them.

  Implementer fallback: if the LLM emits the deflection text but forgets the payload flags, the UI detects deflection by exact substring match against the template's first 24 chars: **"That's a "** at the start AND **"— I only know about "** as a substring. Both signals OR'd: render the chip if either is true. Low false-positive rate; cheap.

### 4.2 Visual

```
┌──────────────────────────────────────────┐
│ Sleep team                               │
│ ┌──────────────────────────────────────┐ │
│ │ That's a money thing — I only know   │ │  ← deflection bubble
│ │ about sleep. Want me to ping the     │ │
│ │ money team, or paste it in the       │ │
│ │ Outkeep chat?                        │ │
│ └──────────────────────────────────────┘ │
│   [ Take this to Outkeep ]               │  ← DeflectionChip
└──────────────────────────────────────────┘
```

- Capsule chip, corner radius 18pt (half height).
- Background: `Color.signalFlame.opacity(0.12)`.
- Foreground (label and trailing SF symbol): `Color.signalFlame`.
- Label: **"Take this to Outkeep"** in `Font.body.weight(.semibold)`. Trailing SF `arrow.up.forward.app` 14pt regular, same color.
- Padding: 14pt horizontal, 9pt vertical.
- Position: 8pt below the deflection bubble, leading-aligned to match the bubble (NOT centered).
- 4pt vertical bottom margin before the next message (or input bar).

### 4.3 Tap behavior

1. Read `original_user_message` from the deflection event's payload (or, fallback: read the user's most recent `chat_turn` in this tile that immediately preceded the deflection — there should be exactly one).
2. Copy that text into the coordinator chat's draft field via `ChatViewModel(thread: .coordinator).setDraft(_:)` — this is a new method on the long-lived coordinator VM that writes to its `@Published var draft: String`. The draft persists across navigation.
3. Pop `DomainDetailView` off the nav stack (return to landing).
4. Push `CoordinatorChatView`. On appear, the input bar's text field reads the draft and renders it. User reviews and taps send.
5. Chip dismisses (one-shot — it's part of the static bubble layout, not stateful). The deflection bubble itself stays in the tile chat as history.

**Critical:** the chip does NOT auto-send the message. The user reviews and edits in the coordinator chat draft before sending. This preserves agency per the v2 empty-state-script "always one-tap with chips that fill, never send" rule.

### 4.4 Chip-not-shown edge cases

- If the user already left the tile and came back (rare): the chip still renders on the historical deflection bubble. Tapping it still copies `original_user_message` into coordinator draft and navigates. No staleness check.
- If the user replies to the deflection in tile chat anyway (e.g., types a sleep-related question after the deflection): the chip stays on the old deflection bubble; the new exchange continues normally below.
- If the deflection event lacks the payload flags AND the substring detection fails: no chip. The deflection text still renders as a normal bubble. User has to manually navigate. Acceptable degradation.

---

## 5. GearOverlay (Settings)

Per UXR §4.4: full-screen modal cover (not a sheet), with its own internal `NavigationStack`. Audit log pushes as a detail view inside the modal.

### 5.1 Presentation

- Triggered by gear icon tap in `AgentGridView` (only).
- Presented via SwiftUI `.fullScreenCover(isPresented:)` — NOT `.sheet`. Reason: the audit log, per-domain settings, and export flows need real navigational depth, and sheet's grabber + partial-height behavior reads as "shallow modal."
- Modal hosts an internal `NavigationStack` for push/pop within Settings.
- Top-leading: **"Done"** button (`.cancellationAction` toolbar item) dismisses the modal back to landing. State preserved on dismiss (audit log scroll position, etc., reset on re-open — no persistence in v1.5.0).
- Drag-down-to-dismiss: enabled by default with `.interactiveDismissDisabled(false)`. (UXR §4.4 says "Modal can be dismissed by swipe-down from any screen depth" — confirm with implementer test that this works from pushed audit-log view.)

### 5.2 Content (sections — same as v1 `ui-specs.md` §3)

Reuse the v1 Settings sections verbatim. No functional changes in v1.5.0.

Section order:

1. **TIMING** — Morning brief, Quiet hours, Max nudges per day, Minimum gap between nudges
2. **MODES** — Mercy mode, Pause
3. **LIFE TEAMS** — list of active domains (rows tap into per-team `DomainDetailView`'s gear → `TeamSettingsView`, which is the SAME view used from inside a tile; reuse component, just present via push from this list)
4. **ACTIVITY** — Recent actions (push to `AuditLogView`)
5. **CAPTURE** — Voice input toggle, iCloud Drive mirror toggle
6. **ABOUT** — Foundation Models status, app version, Export event log

**Per UXR §5.5:** the **"+ Add a team via chat"** row at the bottom of LIFE TEAMS section (from v1) is **REMOVED in v1.5**. Its function is now served by the "+ Spawn a team" tile on landing. Reasoning: two entry points for the same action is exactly the redundancy this rework eliminates. The landing CTA is the only spawn affordance.

All other Settings copy and layout: identical to `ui-specs.md` §3. Implementer reuses existing `SettingsView` body almost verbatim; the only deltas are (a) presentation harness changes from `TabView` member to `.fullScreenCover`, (b) "+ Add a team via chat" row deletion, (c) toolbar gains a "Done" leading item.

### 5.3 Per-team gear vs global gear

- **Global gear (AgentGridView toolbar):** opens this full-screen overlay. Cross-team settings + activity log + capture + about.
- **Per-team gear (DomainDetailView toolbar):** opens `TeamSettingsView` as a `.sheet`. Just rename, tone, archive for that one team.

These are different surfaces and should remain so. Do NOT route the per-team gear through the global Settings modal — that would create a deep-link confusion ("did I come from a tile or from settings?").

---

## 6. Empty states

### 6.1 Zero teams (cold-launch first run)

This is the user's first view ever, possibly within minutes of install. Most important moment after the v1 empty-state script.

```
┌─────────────────────────────────────────────┐
│  Outkeep                              ⚙      │
├─────────────────────────────────────────────┤
│                                              │
│  ┌───────────────────────────────────────┐  │
│  │ ✦  Tell me what's on your mind, or    │  │  ← coordinator chat box
│  │    hold the mic to talk.              │  │
│  └───────────────────────────────────────┘  │
│                                              │
│                                              │  ← Up-Next strip: hidden (empty)
│                                              │
│  ┌─────────────────────────────────────────┐│
│  │                                         ││
│  │              ✦                          ││  ← full-width "+ Spawn a team"
│  │                                         ││     CTA — 173pt tall
│  │        + Spawn a team                   ││
│  │                                         ││
│  │   This is where your teams live.        ││
│  │   Tap to start.                         ││
│  │                                         ││
│  └─────────────────────────────────────────┘│
│                                              │
│  Or talk to Outkeep up top — anything you    │  ← .caption helper text,
│  type there gets handled.                    │     8pt below CTA tile,
│                                              │     16pt h-margin, centered
└─────────────────────────────────────────────┘
```

**Critical deltas from regular spawn tile:**
- The "+ Spawn a team" tile becomes **full-width** (spans both grid columns) in zero-teams state. Aspect ratio drops from 1:1 to roughly 2:1 (height stays ~173pt).
- Dashed border treatment is the same as the half-width variant.
- Sparkle is larger (36pt instead of 28pt).
- Label and subtext sizes unchanged.

**Helper text below the CTA tile** (only in zero-teams state):
- Verbatim: **"Or talk to Outkeep up top — anything you type there gets handled."**
- `Font.caption`, secondary-label color, centered, max-width 320pt.
- 8pt below the CTA tile.
- This is the bridge between the two entry points (chat box vs spawn tile) — it tells the user both paths work, neither is "the right one."

**Forbidden alternatives** (will be rejected on review):
- ~~"Get started by creating your first team."~~ — quiz energy.
- ~~"You don't have any teams yet."~~ — frames absence as failure.
- ~~Any UI affordance to spawn that bypasses chat.~~ — violates spec §2 #9.

### 6.2 Tile Chat sub-tab — empty (no events for this domain)

User has spawned a team but hasn't logged anything to it yet (and there's no notification deep-link prompt). Tile chat opens to a blank thread.

```
┌─────────────────────────────────────────────┐
│  [ Chat ]  [ Sheet ]                         │
├─────────────────────────────────────────────┤
│                                              │
│                                              │
│         (Sleep team color tinted             │
│            sparkle, 44pt)                    │
│                                              │
│         I'm the Sleep team.                  │
│         Tell me what to track,               │
│         or just log something now.           │
│                                              │
│                                              │
├─────────────────────────────────────────────┤
│ [✦  Type or hold the mic to talk.    ] [→] │
└─────────────────────────────────────────────┘
```

- Sparkle SF Symbol, 44pt, color = `DomainColor.for(domain)`.
- Greeting body: **"I'm the {Domain.display_name} team. Tell me what to track, or just log something now."** — 2 lines, `Font.body`, primary-label color, centered, max-width 280pt.
- Greeting block is rendered by the UI when `events.count == 0 WHERE domain = ?`. After the user's first message, it disappears (one-shot, same pattern as the v1 coordinator first-launch greeting per `ui-specs.md` §1.7).
- The greeting block is **not an event row** — it never persists.
- Note: this is a flexible greeting (uses `{display_name}`) since teams have arbitrary user-chosen names. The team-agent identity is established here so the user knows whose room they're in.

### 6.3 Tile Sheet sub-tab — empty (no instruments yet)

User has spawned a team via the empty-state script but didn't add an instrument during Branch B (skipped B3, or new team via "+ Add a team" not via the v2 script). Sheet tab has nothing to show.

```
┌─────────────────────────────────────────────┐
│  [ Chat ]  [ Sheet ]                         │
├─────────────────────────────────────────────┤
│                                              │
│  Last updated never        [ + Add a track ] │  ← header strip stays visible
│                                              │
│                                              │
│         (small bar-chart SF, 36pt,           │
│            secondary label color)            │
│                                              │
│         This team has no instruments yet.    │
│         Tap "+ Add a track" above            │
│         or ask in Chat.                      │
│                                              │
│                                              │
│  ┌─────────────────────────────────────────┐│
│  │ ▸ All events                             ││  ← still rendered;
│  └─────────────────────────────────────────┘│     expanding shows 0 results
│                                              │
└─────────────────────────────────────────────┘
```

- Icon: SF `chart.bar.xaxis` (or `chart.line.uptrend.xyaxis` — implementer's call; both convey "track" without judgment), 36pt, secondary-label color.
- Body: **"This team has no instruments yet."** + **"Tap '+ Add a track' above or ask in Chat."** — `Font.body`, secondary-label color, centered, max-width 280pt, 2 lines.
- "Last updated" string in the header shows **"Last updated never"** in this state (no italics, no shame copy).
- The "+ Add a track" header button still works and routes to Chat sub-tab with the team agent's pre-seeded prompt.
- The "All events" disclosure still renders; expanding it shows zero rows with text **"Nothing yet."** in `Font.caption`, secondary-label color, centered.

### 6.4 Up-Next strip — empty (no commitments/notifications in next 12h)

- Strip is **removed from layout entirely**, zero height, no placeholder. Per UXR §5.3.
- No "Nothing on deck" copy on landing. The user's eye flows straight from the chat box to the tile grid.

### 6.5 Coordinator chat (full surface) — empty for a Nth-team return user

User returns to the app days later, taps the coordinator chat box, and their thread is empty (or only the morning brief). No special empty state for this — the existing `ChatView` renders whatever messages exist, possibly just the brief. No greeting block, no placeholder body. Input bar always shows the normal placeholder.

---

## 7. State diagrams

### 7.1 Notification deep-link → tile chat (per UXR §3.3)

```
   [system delivers notification]
              │
              ▼
   ┌─────────────────────────┐
   │ user taps banner        │
   └─────────────┬───────────┘
                 ▼
   ┌─────────────────────────────┐
   │ NotificationActionRouter    │
   │ decodes context             │
   └─────────────┬───────────────┘
                 │
   ┌─────────────┴──────────────────┐
   │                                │
   ▼                                ▼
context.domain == nil       context.domain != nil
   │                                │
   ▼                                ▼
[push CoordinatorChatView]   [push DomainDetailView(domain:)
                              + force-select .chat sub-tab]
   │                                │
   ▼                                ▼
[inject suggestedPrompt      [inject suggestedPrompt
 as coordinator bubble in     as coordinator-flagged bubble in
 coordinator chat]            tile chat (rendered DomainBubble
                              with "From a notification" caption)]
   │                                │
   ▼                                ▼
[user reads, optionally       [user reads, optionally
 replies to coordinator]       replies to team agent]

   Malformed-context fallback: land on AgentGridView,
   show SystemNoteRow in coordinator chat: "A notification's
   context didn't load. Tap to open Outkeep as usual."
```

### 7.2 Coordinator handoff flow — where messages appear

User typed in coordinator chat: **"how's sleep this week?"**

```
   [user typed in coordinator chat box → expanded view]
              │
              ▼
   [event written: actor='user', domain=NULL, kind='chat_turn']
              │ user bubble appears in coordinator chat
              ▼
   [AgentLoop.run(userMessage:) starts coordinator turn]
              │
              ▼
   [coordinator decides handoff to 'health']
              │
              ▼
   [AgentHandoffTool.invoke runs Sleep agent]
              │
              ▼
   [Sleep agent emits tool calls — e.g. instrument.read]
              │
              ├─► event row: actor='agent:health', kind='instrument_read',
              │              domain='health'  (visible in Sheet tab events)
              │
              └─► (no chat_turn yet)
              │
              ▼
   [Sleep agent returns its text reply]
              │
              ▼
   [AgentHandoffTool emits a chat_turn event:
    actor='agent:health', kind='chat_turn', domain=NULL]
              │ DomainBubble appears in COORDINATOR chat
              │ with "Sleep team" speaker label above
              ▼
   [coordinator may emit a synthesizing follow-up bubble
    of its own — actor='coordinator', domain=NULL]
              │ Coordinator bubble appears in coordinator chat

   What the user sees in each surface:
   ─ Coordinator chat: user message → Sleep bubble → coordinator bubble
   ─ Sleep tile Chat sub-tab: nothing new (filtered out)
   ─ Sleep tile Sheet > All events: instrument_read row (the state-touching tool call)
```

The key invariant: **chat turns get the `domain` of where the user typed them, not the agent who replied** (UXR §2.7).

### 7.3 Direct-to-tile capture flow

User taps Sleep tile, types **"took a 40 min nap"**:

```
   [user typed in Sleep tile chat]
              │
              ▼
   [event written: actor='user', domain='health', kind='chat_turn'
    via EventLog.insertChatTurn chokepoint]
              │ user bubble appears in tile chat
              ▼
   [AgentLoop.runDomainTurn(domain:'health', ...) starts]
              │ (skips coordinator entirely)
              ▼
   [Sleep agent emits event.capture + instrument.apply_event]
              │
              ├─► event row: actor='agent:health', kind='log_entry',
              │              domain='health' (audit lane)
              │
              └─► event row: actor='agent:health', kind='instrument_update',
                             domain='health' (audit lane + drives tile face refresh)
              │
              ▼
   [Sleep agent emits chat_turn reply:
    actor='agent:health', kind='chat_turn', domain='health']
              │ DomainBubble appears in TILE chat only
              ▼
   [user backs out to landing]
              │
              ▼
   [Sleep tile face re-renders: primary value updated, freshness "logged 0m ago"]

   What the user sees in each surface:
   ─ Sleep tile Chat sub-tab: user message → Sleep bubble (the reply)
   ─ Coordinator chat: nothing new
   ─ Sleep tile Sheet > All events: log_entry + instrument_update rows
   ─ Landing tile face: refreshed value + freshness
```

### 7.4 Spawn flow — typed phrase OR CTA tile

Both entry points converge on the same v2 Branch B script. The only difference is the seed.

```
   ┌────────────────────────────────┐         ┌────────────────────────────────┐
   │  Entry A: user types in        │         │  Entry B: user taps "+ Spawn   │
   │  coordinator chat:             │         │  a team" tile                  │
   │  "spawn me a money agent"      │         │                                │
   └─────────────┬──────────────────┘         └──────────────┬─────────────────┘
                 │                                            │
                 ▼                                            ▼
   [event: user, domain=NULL,                    [push CoordinatorChatView]
    kind='chat_turn']                                          │
                 │                                            ▼
                 ▼                                  [inject coordinator bubble:
   [coordinator runs through its                    "Want to add a new team —
    normal routing pass; recognizes                  what would you like me to
    setup intent → routes to                         help carry? Name and tone
    Branch B inside its empty-state                  are up to you; I'll propose
    state machine]                                   a starting shape."
                 │                                   (this is event:
                 │                                    actor='coordinator',
                 │                                    domain=NULL, kind='chat_turn')]
                 │                                            │
                 ▼                                            ▼
                 └────────────────┬───────────────────────────┘
                                  ▼
   [v2 Branch B runs from B1 onward — already implemented in
    CoordinatorEmptyStateCopy.swift; no new branching code]
                                  │
                                  ▼
   [Branch B exits via B7]
                                  │
                                  ▼
   [domain.create writes new domain row]
   [optional instrument.create writes new instrument rows]
   [optional notification.schedule_recurring writes morning/wind-down nudges]
                                  │
                                  ▼
   [user pops back to landing; new tile appears in the grid (after the existing
    tiles, before the "+ Spawn a team" CTA)]
```

---

## 8. Surface migration table (implementer-actionable)

This is the implementer-grade version of UXR §5.5. Every v1 view either moves, gets reused, or gets deleted.

| v1 component | v1.5 outcome | Notes |
|---|---|---|
| `RootTabView.swift` | **DELETE** | Replaced by `RootView.swift` hosting `AgentGridView`. Per Arch Appendix A. |
| `ChatTab` (the v1 Chat tab body) | **Move and reuse** as `CoordinatorChatView` pushed from `AgentGridView`. Same `ChatView` body; new `@StateObject ChatViewModel(thread: .coordinator)` (long-lived, owned by `RootView`). | Behavior identical; UI chrome unchanged inside the chat view. |
| `ChatEmptyState` (v1 first-launch greeting per `ui-specs.md` §1.7) | **Reuse** inside `CoordinatorChatView` when `events WHERE domain IS NULL` count is 0. | The greeting is still UI-rendered, not LLM. Time-of-day variant and suggestion chips per `coordinator-empty-state-v2.md`. |
| `TodayView.swift` (v1 Today tab body) | **DELETE** | Functionality redistributed: morning brief → coordinator chat box preview (§1.4.3); instrument cards → tile faces (§2.2); Upcoming → Up-Next strip (§1.5). |
| `MorningBriefCard.swift` | **Reuse inside `CoordinatorChatView`** as a one-off bubble variant when the brief is the most recent assistant turn, OR delete and render the brief as a normal coordinator bubble (implementer's call). Either way: **NOT** rendered at the landing root level. | The collapsed preview on landing is a separate, simpler component — just text + accent stripe inside the chat box. |
| `InstrumentCard.swift` (v1 Today tile) | **Repurpose** as the source of the per-kind value/delta formatter used by `TeamTileView` (which becomes the new "tile face" component). The visual layout from `InstrumentCard` partially reuses (typography for the value), but the chrome (background, padding, shape) is replaced by `TeamTileView`'s container chrome. | Don't render `InstrumentCard` as-is anywhere in v1.5; reuse its `kind → value-string` formatter as a pure function. |
| `InstrumentGridView.swift` (v1 in-app spreadsheet grid) | **Reuse verbatim** inside `DomainSheetView` per-instrument section bodies. Drop the back-button chrome since it's no longer pushed; otherwise unchanged. | This is the canonical spec §12.1 grid. |
| `UpcomingList.swift` (v1 Today section) | **Refactor** as `UpNextStripView` rendering the same source data (commitments + notifications WHERE due/scheduled within 12h) but as horizontal chips, max 2 visible. | Reuse the underlying query; replace the list-row UI with chip UI. |
| `TodayEmptyState.swift` (v1 "Nothing here yet — and that's the right starting point.") | **DELETE** | The empty Today state no longer exists. The new empty-landing state is §6.1 above. |
| `SettingsView.swift` (v1 Settings tab body) | **Reuse** as the content of `GearOverlay`. Minor edits: add Done toolbar item, remove "+ Add a team via chat" row from LIFE TEAMS section. | Functional content unchanged. |
| `DomainDetailView` (v1 — pushed from Settings → Life Teams row) | **Move and reuse** as `TeamSettingsView`, presented via `.sheet` from `DomainDetailView`'s toolbar gear AND pushed from `GearOverlay`'s LIFE TEAMS section. Same content view, two callers. | Per UXR §4.4. |
| `AuditLogView.swift` | **Reuse verbatim** inside `GearOverlay`'s nav stack. Same content, same behavior, same per-action Undo buttons. | Reachable only via Settings now (no other entry point). |
| `ChatInputBar.swift` | **Reuse verbatim** in both `CoordinatorChatView` (landing → pushed) and `DomainDetailView`'s Chat sub-tab. Placeholder text differs (see Copy block §9). | Mic, send, voice states all unchanged. |
| `DomainBubble.swift` / `CoordinatorBubble.swift` / `UserBubble.swift` / `ToolCallCard.swift` / `HandoffIndicator.swift` / `ThinkingBubble.swift` | **Reuse verbatim** | v1's chat components are fine. Only the parent layout changed. |
| `DomainColor.swift` | **Reuse verbatim** | Same hash, same colors. Used by tile stripes, tile face accents, sub-tab bar color stripe, deflection chip in tile contexts. |
| Notification deep-link handler (v1 `NotificationActionRouter` + `RootTabView.onAppear` buffer drain) | **Refactor:** the router stays; the UI bridge moves into `RootView.onAppear` / `.onChange` and now branches on `context.domain` per Arch §6. | No schema change to `NotificationActionContext`. |
| New: `AgentGridView.swift` | NEW | The landing surface. See §1 above. |
| New: `TeamTileView.swift` | NEW | The tile cell. See §2 above. |
| New: `DomainDetailView.swift` (v1.5 version — DIFFERENT from v1's `DomainDetailView`) | NEW | The tile-detail tabbed surface. See §3 above. Rename v1's `DomainDetailView` to `TeamSettingsView` to avoid the name collision. |
| New: `DomainSheetView.swift` | NEW | Sheet sub-tab body. See §3.5. |
| New: `UpNextStripView.swift` | NEW | Horizontal chip row. See §1.5. |
| New: `DeflectionChip.swift` | NEW | See §4. |
| New: `RootView.swift` | NEW | Root container; hosts `AgentGridView` + `GearOverlay` presentation state. |

---

## 9. Copy block (verbatim, ready to paste)

All strings below are final. Implementer copies these into Swift string literals exactly. Do NOT paraphrase.

### 9.0 Brand strings (splash, About)

- Product wordmark: **"Outkeep"** — verbatim, capital O, never "OutKeep" / "outkeep" / "OUTKEEP".
- Motto (splash, About): **"Structure your life. Make better choices."** — verbatim, including both periods.
- Splash VoiceOver label: **"Outkeep. Structure your life. Make better choices. Loading."**
- FM-unavailable takeover heading: **"Foundation Models isn't available."**
- FM-unavailable body: **"Outkeep runs on Apple's on-device model. To use Outkeep, enable Apple Intelligence in Settings → Apple Intelligence & Siri."**
- FM-unavailable buttons: **"Open Settings"** and **"Try again"**.

### 9.1 Coordinator chat box (landing)

- Normal placeholder: **"Tell me what's on your mind, or hold the mic to talk."**
- FM unavailable placeholder: **"Outkeep is offline — tap for details."**
- Brief preview format (assemble at runtime): **"This morning · {brief first sentence, ≤80 chars}. Tap to read the full brief."**
  - Variants for time-of-day (matching `CoordinatorEmptyStateCopy.greeting(forLocalHour:)`):
    - ≥04:00 & <12:00 → **"This morning · …"**
    - ≥12:00 & <17:00 → **"This afternoon · …"**
    - else → **"This evening · …"**
    - 00:00–04:00 → **"Tonight · …"** (separate case; the greeting word-drops handled inside the chat itself, not the preview)

### 9.2 Up-Next strip

- Chip format (assembled at runtime): **"{HH:mm AM/PM}  {short label}"** — e.g., **"10:30 PM  Wind-down"**. Single space after the time. Truncate label to fit 24 total chars including the time.
- Strip empty state: NONE (hidden entirely).

### 9.3 Team tile face

- Name format: **"{display_name} team"** — implementer appends " team" in one place, not in the stored `display_name`.
- Freshness formats (from `FreshnessFormatter`):
  - <2 min: **"logged just now"**
  - 2–59 min: **"logged {N}m ago"**
  - 1–23 hours: **"logged {N}h ago"**
  - 1–6 days: **"logged {N}d ago"**
  - ≥1 week: **"logged {N}w ago"**
  - last_logged_at is nil: **"no logs yet"**
  - last_logged_at is today but >24h interval flag set on a daily-cadence instrument: **"not yet today"**
- No-instrument state on tile face: **"No tracks yet"** (line 1) / **"tap to add one"** (line 2).
- Failed-to-load state: value **"—"**, freshness **"couldn't read this tile"**.

### 9.4 "+ Spawn a team" CTA tile

- Label: **"+ Spawn a team"**
- Subtext: **"This is where your teams live. Tap to start."**
- Pre-seeded coordinator bubble on tap: **"Want to add a new team — what would you like me to help carry? Name and tone are up to you; I'll propose a starting shape."**

### 9.5 Zero-teams landing helper text

- Below the full-width CTA: **"Or talk to Outkeep up top — anything you type there gets handled."**

### 9.6 DomainDetailView header & sub-tabs

- Back-button label: **"Outkeep"** (back chevron auto-renders from NavigationStack).
- Title: **"{display_name} team"**
- Sub-tab labels: **"Chat"** and **"Sheet"** (verbatim).

### 9.7 Tile Chat input bar

- Placeholder: **"Type or hold the mic to talk."**
- In-flight placeholder: **"{display_name} team is working…"** — substitute `display_name` (NOT with " team" suffix; the word "team" already appears in the sentence).
- Note: this placeholder is intentionally shorter than the coordinator chat box's. The coordinator's placeholder asks the user to share intent ("what's on your mind"); the tile's just says "go ahead" because the user has already chosen the room.

### 9.8 Tile Chat empty greeting

- Body: **"I'm the {display_name} team. Tell me what to track, or just log something now."** — `display_name` is whatever the user picked at spawn time.

### 9.9 Sheet tab

- Header strip "Last updated" formats: **"Last updated {relative}"** / **"Last updated never"**
- "+ Add a track" button label: **"+ Add a track"**
- Team-agent prompt when "+ Add a track" is tapped (pre-seeded in tile Chat sub-tab): **"Want to add a track here? Tell me what you'd like me to keep an eye on."**
- All-events disclosure label: **"All events"** (with chevron prefix from the disclosure view).
- All-events empty: **"Nothing yet."**
- No-instruments empty body: line 1 **"This team has no instruments yet."** / line 2 **"Tap '+ Add a track' above or ask in Chat."**

### 9.10 DeflectionChip

- Chip label: **"Take this to Outkeep"** (trailing SF `arrow.up.forward.app`).
- The deflection sentence itself (LLM-emitted via role-prompt template): **"That's a {guessed_domain} thing — I only know about {your_domain_name}. Want me to ping the {guessed_domain} team, or paste it in the Outkeep chat?"**

### 9.11 TeamSettingsView

- Title: **"{display_name} team"**
- Section headers: **"NAME"**, **"TONE"**, **"ACTIONS"** (uppercase via `.textCase(.uppercase)`).
- Tone options (verbatim from `coordinator-empty-state-v2.md` §7):
  - **"Stay gentle. Just track."** (default)
  - **"Push back a little when I'm slipping."**
  - **"Push hard. Call me out when needed."**
- Custom (user-edited) tone label: **"Custom"**
- Tone-replace confirmation: **"Replace your edited instructions with this preset?"** Buttons: **Replace** / **Cancel**.
- Disclosure label: **"See exact instructions"**
- Archive button label: **"Archive this team"**
- Archive confirmation (verbatim from v1): **"Archive {display_name} team? Its instruments stop updating. You can still see history."** Buttons: **Archive** / **Cancel**.

### 9.12 GearOverlay

- Title: **"Settings"**
- Done button: **"Done"** (leading toolbar item).
- All section headers and rows: identical to `ui-specs.md` §3.
- LIFE TEAMS section: **DELETE** the "+ Add a team via chat" row. Replace with: nothing — the section just lists active teams; spawn happens on landing.

### 9.13 Notification malformed fallback

- SystemNoteRow in coordinator chat (verbatim, carried over from v1 with rename): **"A notification's context didn't load. Tap to open Outkeep as usual."**

### 9.14 v1 `ui-specs.md` strings carried over (no change)

All other strings from `ui-specs.md` v1 — chat bubble component copy, tool-call card labels, mercy/pause action sheets, audit log row formats, AboutSection — remain verbatim. v1.5 does not alter them.

---

## 10. Pushback / unresolved calls

Items where this doc deviates from UXR / Arch, or where the call was made by Designer:

1. **Sparkle icon in the coordinator chat box, not a mic icon.** UXR §5.1's ASCII shows `🎙` as the left affordance. I'm specifying `sparkle` instead, because the mic implies hold-to-talk inline (which the collapsed box doesn't do) and `sparkle` matches v1's coordinator identity icon used in the first-launch greeting. The mic lives only inside the expanded chat's input bar. **Status: Designer call. Override-able if Implementer or team-lead disagrees.**

2. **Sub-tab bar uses SwiftUI `Picker(.segmented)`, not a custom or `TabView`-based segmented control.** UXR §5.2's ASCII implies a custom control; the right iOS-native primitive is the segmented Picker, which renders correctly with Dynamic Type and avoids gesture-conflict landmines with `NavigationStack`. **Status: clarification, not a deviation.**

3. **Unread dot on tile face is laid out in v1.5.0 but invisible (opacity 0).** Arch §10 defers the underlying `last_view_ts` table to v1.6. Implementing the visual slot now means v1.6 can flip a feature flag without reflowing the tile layout. **Status: matches Arch; calling out for clarity.**

4. **"+ Add a team via chat" Settings row is removed in v1.5.** UXR §5.5's surface migration says yes. I'm restating it explicitly because the redundancy was a real v1 surface and the implementer might reflexively port it. **Status: removal confirmed.**

5. **Coordinator-injected bubble in tile chat (notification deep-link case) is the only documented exception to "coordinator never speaks in tile."** Arch §2's filter rule `WHERE domain = ? AND kind = 'chat_turn'` includes it because the kind matches and the domain matches; the actor='coordinator' field is what tells the UI to render it with the "From a notification" caption. I've drawn this distinction sharply because future implementers will look at the rule and think "but the coordinator isn't supposed to be in tile chat" — the answer is "this exact case, yes, and only because it was the user who routed it here via a notification tap." **Status: Designer call; documented for clarity.**

6. **Spawn flow does NOT auto-send the seed message from the CTA tile — coordinator emits the bubble, user types their answer.** This matches UXR §2.5 and the v2 Branch B flow but the team-lead briefing was slightly ambiguous about whether the CTA seeds a coordinator bubble or a user-side draft. The right answer is coordinator bubble (the user landed here pre-asked; they answer). **Status: confirmed against UXR.**

7. **`agent.cross_consult` not in v1.5 scope.** Locked by team-lead per Arch Appendix C. Not surfaced anywhere in this doc. **Status: locked.**

8. **"+ Spawn a team" tile is half-width when there are ≥1 real teams, full-width only in zero-teams empty state.** UXR's §5.1 mockup shows the spawn tile as half-width in the non-empty case (paired with Home team at the bottom of a 3-team example). I've specified that explicitly so Implementer doesn't add a "fill the row" treatment for odd-count cases. **Status: matches UXR §5.1 implicitly; making it explicit.**

9. **Unaddressed: iPad and Mac layouts.** v1.5.0 ships iPhone-only per UXR §6. The 2-column adaptive grid scales naturally to 3 and 4 columns at wider widths, but I have not specified per-column-count nav behavior or whether the gear should be a sidebar on iPad. v1.6.

10. **Unaddressed: drag-to-reorder tiles.** v1.5.0 ships creation-order; reordering is v1.5.x per UXR §6.

---

## 11. Drift criteria (what counts as failed grading)

Adapted from `ui-specs.md` §7. When team-lead or UXR reviews the implemented build, the following count as drift that blocks ship:

1. Any moralizing or shame copy not in this file. "Missed", "overdue", "X days behind", "let's get back on track" — all banned.
2. Tile face shows anything other than the three documented elements (name, value, freshness) plus the v1.6-deferred unread dot slot.
3. Tile face uses red/green stoplight color on value or delta. Color is `.label` / `.secondaryLabel` only.
4. "+ Spawn a team" tile uses a solid-border style or `.secondarySystemGroupedBackground` background, making it indistinguishable from a real team tile.
5. Coordinator chat box looks like a tile (same shape, same background, same accent). It's a distinct affordance with different chrome.
6. Tile chat shows handoff replies originating from the coordinator chat (filter must be `WHERE domain = ? AND kind = 'chat_turn'`; handoff replies have `domain=NULL`).
7. Coordinator chat shows tile chat history (filter must be `WHERE domain IS NULL AND kind IN ('chat_turn', 'handoff_summary')`).
8. Today tab still exists anywhere in the UI.
9. Bottom tab bar still exists (`TabView` at root level is gone).
10. The "+ Add a team via chat" row still exists in Settings → Life Teams.
11. Spawn flow has a "Create Team" form anywhere — even hidden, even an "advanced" path. Spawn is always through chat.
12. Settings is presented as a `.sheet` (it must be `.fullScreenCover` for v1.5).
13. Per-team gear menu is folded into global Settings, or vice versa. They're separate surfaces.
14. DeflectionChip auto-sends the message to coordinator instead of seeding a draft.
15. The brief preview in the coordinator chat box auto-dismisses on a timer. It only clears on explicit × or on opening coordinator chat.
16. Sub-tab bar uses a custom control instead of SwiftUI `Picker(.segmented)`.
17. **Brand:** the wordmark renders as anything other than **"Outkeep"** (verbatim, capital O, single word). The motto **"Structure your life. Make better choices."** is paraphrased, missing punctuation, or split across surfaces (splash only — never inline in chat or tiles).
18. **Brand:** primary accent renders as system blue or any non-`Color.signalFlame` color. CTAs, send button, mic recording state, focus stripes, brief-preview accent stripe, deflection chip, sparkle in coordinator chat box — all must use `Color.signalFlame`.
19. **Brand:** "Steward" appears in any user-facing string. The only permitted "Steward" reference in v1.5 is internal (Swift module name, file paths, xcodeproj, `v0.9.6-sunday-morning` historical tag).
20. **Brand:** TeamTile name does not use `Font.satoshi(.bold, size: 18)`, or primary value does not use `Font.satoshi(.medium, size: 24).monospacedDigit()`. These are the two most face-of-the-product type choices.
21. **Brand:** Splash screen omits the lighthouse emblem, the wordmark, or the motto. All three must appear together.

---

## 12. What's intentionally NOT in this spec (Implementer's call)

Same envelope as v1 spec §8:

- Animation timing curves (default `.easeInOut(duration: 0.2)`).
- Exact pixel padding values not specified (use 8/12/14/16 multiples).
- Haptic feedback frequency beyond the ones called out in v1.
- Shimmer shader implementation.
- Pull-to-refresh customization on `CoordinatorChatView` (system default).
- Whether `DomainDetailView`'s back chevron uses the system default chevron label (**"Outkeep"**, per nav-stack auto-labeling matching the AgentGridView title) or a custom one (still **"Outkeep"** — the back-target IS Outkeep).

If you find yourself wanting to add a screen, modal, or persistent UI element not in this spec, **ask team-lead first.** Scope discipline: build what's here completely, not extra things half-way.

---

**End of spec. Implement deterministically. When tone drifts, re-read §6.1, §6.2, §9, and `ui-specs.md` §4 (tone-of-voice cheat sheet, still load-bearing).**
