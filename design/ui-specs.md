# Steward — UI Specs (v1, Sunday-morning ship)

**Audience:** Implementer (Track E in spec §19).
**Status:** Source of truth for UI. Implementer drift will be graded against this file.
**Voice (all copy):** calm, low-bullshit, non-moralizing, mercy-forward. Never preach about executive function. Never use streak language. Never "let's get back on track." Never "you should have." Lapses are ordinary.

**Platform anchors:**
- SwiftUI, iOS 26+, single device, single user.
- System font (SF), system colors with dynamic type support, dark mode first-class.
- All copy in this file is verbatim — implement as string literals exactly. No paraphrasing.
- No emoji in shipped copy unless this spec includes one.

**Global chrome:**
- `TabView` with three tabs in order: **Chat**, **Today**, **Settings**.
- Default launch tab: **Chat** (the empty-state protocol is the most important moment in v1 — see spec §16).
- Tab bar icons (SF Symbols):
  - Chat → `bubble.left.and.bubble.right`
  - Today → `sun.horizon`
  - Settings → `slider.horizontal.3`
- App accent color: system blue.
- Background: `.systemGroupedBackground` for Today + Settings, `.systemBackground` for Chat.

---

## 1. Chat tab

### 1.1 Screen layout

```
┌─────────────────────────────────────────┐
│  Outkeep                          ⓘ      │  ← nav bar; ⓘ → bottom sheet "What is this?"
├─────────────────────────────────────────┤
│                                         │
│  [coordinator bubble]                   │
│                                         │
│         [user bubble, right-aligned]    │
│                                         │
│  [coordinator bubble]                   │
│  ┌───────────────────────────────────┐  │
│  │ ▸ Outkeep did 2 things            │  │  ← collapsed tool-call card
│  └───────────────────────────────────┘  │
│                                         │
│  [domain agent bubble — Health team]    │
│                                         │
│  ⋯ Health team is thinking              │  ← handoff/thinking indicator
│                                         │
├─────────────────────────────────────────┤
│ [text field…                        ] 🎙 │  ← input bar; mic = hold-to-talk
│                                       ↑ │
└─────────────────────────────────────────┘
```

- ScrollView (reversed scroll behavior: latest message anchored to bottom; new messages animate in from below).
- Auto-scroll to bottom on new message; suppress auto-scroll if user has scrolled up >100pt (offer a small "Jump to latest" pill bottom-right).
- Pull-to-refresh: regenerates last assistant turn (calls `runTurn` with the prior user message). Confirmation alert: **"Re-run last turn? Outkeep will re-do the work."** Buttons: **Re-run** / **Cancel**.

### 1.2 Message bubble styles

Three distinct speakers must be visually unambiguous at a glance:

| Speaker | Alignment | Background | Foreground | Avatar / label |
|---|---|---|---|---|
| User | trailing | `.accentColor` (system blue) | `.white` | none |
| Coordinator | leading | `.secondarySystemBackground` | `.label` | SF Symbol `sparkle` in a circle, label **"Outkeep"** above bubble (only on first bubble in a run) |
| Domain agent | leading | `.tertiarySystemBackground` with a 2pt leading accent stripe in domain color | `.label` | SF Symbol `person.crop.circle` in domain color + label **"{Domain.display_name} team"** above bubble |
| System / error | center | clear; italic `.secondaryLabel` | `.secondaryLabel` | none |

**Domain colors (deterministic from domain string hash):**
- Map `domain` → one of: `.blue`, `.green`, `.orange`, `.purple`, `.pink`, `.teal`, `.indigo`, `.brown`. Stable per domain (hash the string).
- A `DomainColor.for(domain:)` helper is the single source.

**Bubble shape:** rounded rectangle, corner radius 18, tail-less. 10pt vertical padding, 14pt horizontal. Max width 78% of screen.

**Typography:**
- Body: `.body` (17pt, dynamic).
- "Outkeep" / "Health team" speaker label: `.caption` (12pt), `.secondaryLabel`, 4pt below the bubble row above.
- Timestamps: NOT shown inline. Long-press a bubble → context menu with timestamp + Copy + Re-run from here.

**Long-press context menu (per bubble):**
- **Copy** (always)
- **View timestamp** → toast "Yesterday at 10:42 PM" style relative format
- **View reasoning** (assistant bubbles only) → opens tool-call card detail sheet
- **Re-run from here** (user bubbles only) → confirmation: **"Re-run from this message? Anything after will be replaced."** Buttons: **Re-run** / **Cancel**.

### 1.3 Tool-call cards (inline, collapsible)

Tool calls appear **inline** within the assistant's bubble run, NOT inside the bubble — as a separate card below the most recent assistant bubble that produced them. One card per tool call.

**Collapsed state (default):**

```
┌─────────────────────────────────────────────┐
│ ▸ Health team · updated weight_trend         │
└─────────────────────────────────────────────┘
```

- Height: 36pt single row.
- Disclosure chevron `chevron.right` (rotates to down on expand).
- Format: `▸ {actor_short} · {verb} {object}`
  - `actor_short`: "Outkeep" for coordinator, "{Domain} team" for domain agents
  - `verb`/`object` derived deterministically from tool name (table below)
- Tap anywhere on row → expand inline (animated, 0.2s ease).
- Background `.tertiarySystemBackground`, corner radius 10, 10pt horizontal padding.

**Expanded state:**

```
┌─────────────────────────────────────────────┐
│ ▾ Health team · updated weight_trend         │
│                                              │
│  What                                        │
│   instrument.apply_event(weight_trend, 178)  │
│                                              │
│  Why                                         │
│   You logged "weighed 178 this morning."     │
│                                              │
│  Result                                      │
│   weight_trend → 178.4 (7-day avg)           │
│                                              │
│  [ Undo ]   [ Show in Today ]                │
└─────────────────────────────────────────────┘
```

- **What:** tool name + key args, monospaced (`.system(.footnote, design: .monospaced)`).
- **Why:** `reasoning` field from the event row, plain prose, `.footnote`, `.secondaryLabel`.
- **Result:** human-readable outcome string returned by the tool dispatcher (max 2 lines, truncate with "…").
- **Undo button:** visible only if the tool is reversible (calendar.write, calendar.delete, reminder.create, notification.schedule, instrument.apply_event, instrument.create, commitment.create, memory.save). Confirm before destructive undo: **"Undo this? Outkeep will roll it back."** Buttons: **Undo** / **Cancel**.
- **Show in Today** button: visible only for instrument/commitment-related tools; deep-links to the relevant card in Today tab.

**Verb/object table for collapsed labels** (implementer reference — extend deterministically):

| Tool | Verb | Object |
|---|---|---|
| `event.capture` | logged | `{kind}` (or "an event" if unknown) |
| `instrument.create` | started tracking | `{name}` |
| `instrument.apply_event` | updated | `{instrument.name}` |
| `instrument.update_definition` | tuned | `{instrument.name}` |
| `instrument.archive` | archived | `{instrument.name}` |
| `commitment.create` | wrote down | `{title}` |
| `commitment.complete` | marked done | `{title}` |
| `commitment.abandon` | dropped | `{title}` |
| `commitment.snooze` | snoozed | `{title}` |
| `memory.save` | remembered | first 40 chars of text + "…" |
| `memory.forget` | let go of | first 40 chars + "…" |
| `notification.schedule` | scheduled nudge | "{title} at {time}" |
| `notification.schedule_recurring` | scheduled recurring | "{title}" |
| `notification.cancel` | cancelled nudge | "{title}" |
| `calendar.read` | checked calendar | "{N} events" |
| `calendar.write` | added to calendar | "{title}" |
| `calendar.modify` | edited event | "{title}" |
| `calendar.delete` | removed from calendar | "{title}" |
| `reminder.create` | added reminder | "{title}" |
| `reminder.complete` | marked reminder done | "{title}" |
| `domain.create` | spawned | "{display_name} team" |
| `domain.update_prompt` | updated | "{display_name} team role" |
| `domain.archive` | archived | "{display_name} team" |
| `agent.handoff` | handed off to | "{display_name} team" |
| `agent.cross_consult` | asked | "{display_name} team" |
| `mercy_mode.engage` | engaged | "mercy mode until {when}" |
| `pause.engage` | paused | "until {when}" |
| `quiet_hours.set` | set quiet hours | "{start}–{end}" |
| `csv_mirror.sync_now` | synced | "to iCloud Drive" |

**Bundling:** if a single assistant turn produced ≥3 tool calls, show first as expanded, the rest grouped under a single collapsed header **"+ {N} more"** which expands the full list.

### 1.4 Hand-off indicator

When `agent.handoff` runs and the domain agent has not yet returned:

- Inline row, leading-aligned, `.secondaryLabel`, 13pt:
  - SF Symbol `arrow.turn.down.right` + text **"Handing off to {Domain.display_name} team…"**
- Replaces with the domain agent's bubble when the response arrives.

When the domain agent is mid-tool-loop (between hops):
- Show shimmering three-dot indicator inside an empty bubble shaped like the domain agent's:
  - `⋯ {Domain.display_name} team is thinking`
- 12pt `.caption`, italic, `.secondaryLabel`.

When the **coordinator** is processing (no handoff yet):
- Same shimmer dots in a coordinator-styled placeholder bubble. Label above: **"Outkeep"**. Body: just `⋯`.

If a turn exceeds 20s without producing a response, append a faint inline note (system style, center):
- **"Still working. Foundation Models can be slow on first cold start."**

If `MAX_HOPS` is hit (loop fallback from §7):
- Render the coordinator's literal fallback string: **"I went around in circles. Saved what I had."** as a normal coordinator bubble. No special styling.

### 1.5 Input bar

```
┌─────────────────────────────────────────────┐
│ [What's going on?                       ] 🎙 │
└─────────────────────────────────────────────┘
```

- Pinned to bottom, safe-area aware. Background `.systemBackground` with `Material.bar` blur when content scrolls under.
- Height: 52pt resting, grows to multi-line up to 6 lines, then scrolls internally.
- **Placeholder copy** (cycles randomly per app cold-launch from this set — each load picks one and sticks):
  - **"What's going on?"**
  - **"How's it going?"**
  - **"Tell me anything."**
  - **"Log something, ask something."**
  - First-run only (no events yet): **"Type, or hold the mic to talk."**
- Right-edge button changes based on input field state:
  - **Empty field:** mic icon `mic.fill`, system blue. Hold-to-talk (see voice spec 1.6).
  - **Non-empty field:** arrow up `arrow.up.circle.fill`, system blue. Tap to send.
- Disabled (greyed) when a turn is in-flight; placeholder swaps to **"Outkeep is working…"** and field becomes read-only until the turn returns.

### 1.6 Voice input (hold-to-talk)

States:
1. **Idle:** mic icon, system blue.
2. **Recording (finger held):** mic icon turns red `mic.circle.fill`, a waveform bar appears across the input field area animating with audio level. Subtle haptic on press-down. Label above the bar: **"Listening…"** in red.
3. **Transcribing (finger released):** waveform replaced with shimmering three dots; mic icon greys out; label: **"Transcribing…"**. WhisperKit runs.
4. **Done:** transcript drops into the text field. User reviews, edits if needed, taps send. Mic icon returns to blue. (Per spec §14: auto-send default OFF.)

Cancel-while-recording: if the user slides their finger off the button while still pressed, recording cancels with haptic `.notificationOccurred(.warning)`, no transcript drops in. Label briefly shows **"Cancelled."** then fades.

Error states:
- WhisperKit unavailable / fails to load: mic button greyed permanently. Tap shows toast: **"Voice isn't ready right now. You can still type."** No retry button — user can re-toggle voice in Settings.
- Permission denied (microphone): tapping mic shows alert **"Outkeep needs microphone access for voice input."** Buttons: **Open Settings** / **Not now**.

### 1.7 Empty / first-run state

First-launch Chat tab (no `events` rows in DB):

```
┌─────────────────────────────────────────────┐
│  Outkeep                          ⓘ          │
├─────────────────────────────────────────────┤
│                                              │
│                                              │
│         (Outkeep avatar, sparkle SF)        │
│                                              │
│         Morning. I'm Outkeep.               │
│                                              │
│         Tell me something I should           │
│         catch — sleep, money, the            │
│         kitchen, a thing on your mind —      │
│         or say "walk me through it"          │
│         and I'll help you set up a           │
│         first piece.                         │
│                                              │
│                                              │
├─────────────────────────────────────────────┤
│ [Type, or hold the mic to talk.       ] 🎙 │
└─────────────────────────────────────────────┘
```

- Greeting body is `.body`, centered, max-width 280pt, `.label`.
- Avatar is 56pt `sparkle` SF Symbol in `.accentColor`.
- **Time-of-day variant** (deterministic in Swift, not LLM): swap "Morning" → "Afternoon" / "Evening" based on local hour. Hours ≥04:00 & <12:00 → "Morning"; ≥12:00 & <17:00 → "Afternoon"; otherwise → "Evening". Between 00:00 and 04:00 local, drop the greeting word entirely and lead with **"I'm Outkeep."**
- **Suggestion chips** (rendered just below the input bar while the greeting is showing): two tappable chips — **Catch something** and **Walk me through it**. Tapping **Walk me through it** fills the input with literal text `walk me through it` (does NOT auto-send). Tapping **Catch something** focuses the input and swaps the placeholder to **"What should I catch? (sleep, weight, a spend, a thing on your mind…)"** without inserting any text. Chips dismiss once the user sends their first message.
- After the first user message, this greeting (and the chips) disappear (one-shot UI; the user's first message and Outkeep's reply DO get persisted to events as normal turns).
- **Critical:** the greeting block above is rendered by the UI, not by the LLM. The first LLM turn happens when the user sends their first message. The coordinator's empty-state behavior is governed by `design/coordinator-empty-state-v2.md` (canonical) starting from the user's first message.

### 1.8 Offline indicator

When `NWPathMonitor` reports no network:
- Small pill, centered just below nav bar: SF `wifi.slash` + **"Offline — local only"** in `.caption`, `.secondaryLabel`, `.tertiarySystemFill` background, 8pt vertical padding, dismisses to a tiny corner pill after 4s. Tapping the corner pill re-expands.
- Never blocks input. Chat works fully offline per spec §13.

### 1.9 Error states (chat)

- Foundation Models unavailable on launch (e.g., Apple Intelligence not enabled): full-screen takeover (replaces Chat content):
  ```
  Foundation Models isn't available.

  Outkeep runs on Apple's on-device model.
  To use Outkeep, enable Apple Intelligence
  in Settings → Apple Intelligence & Siri.

  [ Open Settings ]   [ Try again ]
  ```
- Tool call failed (transient): the tool-call card renders in expanded state with a red accent stripe and a "Result" section reading: **"This didn't go through: {error_message}. Outkeep kept going."** plus a **Retry** button when retry is safe.
- Turn timed out (>60s wall clock): inline system message **"Outkeep took too long. Saved your message — tap to retry."** Tapping retries with the same input.

---

## 2. Today tab

### 2.1 Screen layout

```
┌─────────────────────────────────────────────┐
│  Today                            ⟳          │  ← nav bar; ⟳ = regen brief
├─────────────────────────────────────────────┤
│  ┌─────────────────────────────────────┐    │
│  │ This morning                        │    │  ← Morning brief card
│  │ (3 sentences, calm, current state)  │    │
│  │                          [ Refresh ]│    │
│  └─────────────────────────────────────┘    │
│                                              │
│  Health team                                 │  ← Section header per domain
│  ┌─────────────┐ ┌─────────────┐            │
│  │ Sleep        │ │ Weight       │            │  ← Instrument cards
│  │ 6.2h         │ │ 178.4        │            │
│  │ −0.4 vs yest │ │ −0.6 vs yest │            │
│  └─────────────┘ └─────────────┘            │
│                                              │
│  Money team                                  │
│  ┌─────────────┐                             │
│  │ Discretionary│                            │
│  │ $172 / $300  │                            │
│  │ this week    │                            │
│  └─────────────┘                             │
│                                              │
│  Upcoming                                    │
│  • 6:30 PM  Call Mom        (commitment)    │
│  • 10:30 PM Wind-down nudge (notification)  │
│                                              │
└─────────────────────────────────────────────┘
```

- ScrollView. Pull-to-refresh re-runs brief generation + refreshes instrument state.
- Sections in fixed order: **Morning brief → instruments (grouped by domain) → Upcoming**.

### 2.2 Morning brief card

- Background: `.secondarySystemGroupedBackground`, corner radius 16, 16pt padding all sides.
- Header: **"This morning"** in `.headline` (or **"Today"** if regenerated after noon local, **"This evening"** after 17:00 local — deterministic in Swift, not LLM-decided).
- Body: 1–4 sentences generated by coordinator. `.body`. Max ~5 lines visible; tap-to-expand if longer.
- **Regen logic** (deterministic, in Swift): on tab appear, if `last_brief.created_at` is null OR >6h ago, kick off generation. Show shimmer placeholder during generation:
  ```
  ┌─────────────────────────────────────┐
  │ This morning                        │
  │ ░░░░░░░░░░░░░░░░░░░░░░░░░          │
  │ ░░░░░░░░░░░░░░░░░░                  │
  └─────────────────────────────────────┘
  ```
- **Refresh button**: bottom-right of card. Always tappable. Calls regen on demand. While regenerating, button shows spinner + label **"Refreshing…"**.
- Brief generation prompts coordinator to **"summarize state, not coach. No moralizing. Mention 1–2 specific instrument values, any commitments in the next 12h, and one optional offer (small, neutral)."**

**Empty-domain morning brief copy** (when domains exist but no events in last 7d for any of them — Swift detects, uses literal): **"Quiet stretch. Nothing's logged in a while. When you're ready, log something or tell me what's up — no pressure."**

### 2.3 Instrument cards

**Card layout (per instrument, 2-column grid on phone, single column on iPhone SE width):**

```
┌─────────────────────────┐
│ {name}                  │  ← .headline, .label
│                         │
│ {value}                 │  ← large display: 28pt rounded
│ {unit}                  │  ← .caption, .secondaryLabel, inline with value
│                         │
│ {delta} vs yesterday    │  ← .footnote, color-coded
│                         │
│ ▸ row of 7 sparkline dots│  ← optional, last 7 days
└─────────────────────────┘
```

- Background: `.secondarySystemGroupedBackground`, corner radius 14, 14pt padding.
- Height: 120pt minimum, grows for longer names.
- Tap → push `InstrumentGridView` (the spreadsheet grid from spec §12 Surface 1).
- Long-press → context menu: **Open grid**, **Edit definition**, **Archive**, **Cancel**.

**Value rendering per `kind`:**

| Kind | Primary value | Delta line |
|---|---|---|
| `running_accumulator` | today's total | "vs yesterday: +X" or "vs 7-day avg: +X" |
| `bounded_budget` | "$172 / $300" (used / limit) | "{N} days left in window" |
| `rolling_average` | current rolling avg | "vs yesterday: −0.4" |
| `countdown_commitment` | "2 / 3" | "{days} left in window" |
| `weekly_evidence_log` | "{N} this week" | "vs last week: +1" |
| `checklist` | "{N} / {total} today" | "{streak_text}" — see below |
| `bounded_window` | "{compliance_pct}%" | "{N} of last 7 nights in window" |

**Delta line color coding (deliberately muted — no green/red of victory/shame):**
- Improvement vs target: `.label` (no color), prepend SF `arrow.up.right` in `.secondaryLabel`.
- Worse vs target: `.label`, prepend SF `arrow.down.right` in `.secondaryLabel`.
- Within ±5%: just `.secondaryLabel`, prepend SF `arrow.right`.
- **Never use** red/orange for "bad" or green for "good." Outkeep doesn't moralize numbers.

**Checklist `{streak_text}`:** intentionally not a streak. Show **"{N} checked today"** — never "X days in a row." Spec §15 bans streak language.

**Loading state per card:** shimmer placeholder over value + delta lines until state recomputes.

**Stale state:** if `last_updated_at` > 48h ago, append `.caption` `.secondaryLabel` line: **"last logged 3d ago"** (relative format). No shame language.

### 2.4 Section headers (per domain)

- Format: **"{Domain.display_name} team"** in `.title3`, `.label`.
- Below: 2pt accent stripe in `DomainColor.for(domain)`, 40pt long.
- Long-press header → context menu: **Open team chat** (opens Chat tab with prefilled handoff `agent.handoff(domain, "")`), **Edit role prompt**, **Archive team**.

### 2.5 Upcoming section

Combines `commitments` (status='active', due within 24h) and `notifications` (scheduled within 24h, undelivered).

```
Upcoming

• 6:30 PM  Call Mom                     (commitment)
• 10:30 PM Wind-down nudge              (notification)  ✕
```

- Each row: time (left, 80pt fixed width, `.body` monospaced digits), title, type pill (small `.caption` `.tertiarySystemFill` rounded).
- Notifications have a trailing `✕` button → dismisses with confirmation: **"Cancel this nudge?"** Buttons: **Cancel nudge** / **Keep**.
- Commitments tap → opens a sheet with: title, due, importance, linked instrument (if any), buttons **Mark done** / **Snooze (1h, 1d, 1w)** / **Drop** / **Close**.
- Section header `.title3`. If empty: render section header + body **"Nothing on deck."** in `.secondaryLabel`, `.body`.

### 2.6 Empty state (NO domains yet)

**Critical:** this state is what the user sees Sunday morning at 7am if they tap Today before Chat. Must NOT shame, MUST NOT quiz, MUST gently route to Chat without making the user feel behind.

```
┌─────────────────────────────────────────────┐
│  Today                                       │
├─────────────────────────────────────────────┤
│                                              │
│                                              │
│              (sun.horizon icon, big)        │
│                                              │
│         Nothing here yet — and               │
│         that's the right starting point.    │
│                                              │
│         Head over to Chat. Tell             │
│         Outkeep something to catch,         │
│         or say "walk me through it."        │
│         That's where the first team         │
│         gets built.                         │
│                                              │
│              [ Open Chat ]                  │
│                                              │
│                                              │
└─────────────────────────────────────────────┘
```

- Icon: SF `sun.horizon` 56pt, `.accentColor`.
- Headline: **"Nothing here yet — and that's the right starting point."** `.title3`, `.label`, centered.
- Body: 3 lines as shown. `.body`, `.secondaryLabel`, centered, max-width 300pt.
- Button: **"Open Chat"** — `.borderedProminent`, switches tab to Chat. Does NOT auto-send a message.

**Voice rationale (don't drift):** "the right starting point" reframes empty as correct, not late. The "something to catch — or say 'walk me through it'" hook mirrors the Chat greeting (§1.7) and the v2 empty-state script (`design/coordinator-empty-state-v2.md` §1.1) — same words across surfaces so the user lands in the same conversation no matter which tab they tap first. Forward-looking framing only; no "hardest to keep up with" / "decay" language anywhere.

**Forbidden alternatives** (do NOT use; team-lead will reject):
- ~~"Get started by creating your first domain!"~~ (quiz energy)
- ~~"Let's set up your life systems."~~ (moralizing, sets up shame for not doing it)
- ~~"You haven't created any domains yet."~~ (frames absence as failure)

### 2.7 Empty state (domains exist, no events today)

```
This morning
Quiet stretch. Nothing's logged in a while.
When you're ready, log something or tell
me what's up — no pressure.

Health team
[Sleep card — last logged 3d ago]
[Weight card — last logged 5d ago]

Upcoming
Nothing on deck.
```

Cards still render with their last known values + a `last logged Nd ago` line. Brief copy is the empty-domain variant from 2.2.

### 2.8 Loading / error states

- Initial load (DB query in flight): full-screen `.progressView()` with caption **"Reading your state…"**.
- Brief generation failed (Foundation Models error): brief card shows **"Couldn't generate a brief just now. State below is fresh."** + Refresh button. Cards still render normally.
- Instrument state recompute failed for one card: that card shows **"Couldn't read this one. Tap to retry."** Other cards unaffected.

---

## 3. Settings tab

### 3.1 Screen layout

Native iOS Settings-style grouped list. SF Symbols for section icons. Sections in this order:

```
┌─────────────────────────────────────────────┐
│  Settings                                    │
├─────────────────────────────────────────────┤
│                                              │
│  TIMING                                      │
│  ─────────────────────────────────────────   │
│  Morning brief             07:00       >    │
│  Quiet hours          22:00 – 05:00    >    │
│  Max nudges per day              3     >    │
│  Minimum gap between nudges  90 min    >    │
│                                              │
│  MODES                                       │
│  ─────────────────────────────────────────   │
│  Mercy mode                       [ off ]   │
│  Pause                            [ off ]   │
│                                              │
│  LIFE TEAMS                                  │
│  ─────────────────────────────────────────   │
│  Health team                            >    │
│  Money team                             >    │
│  + Add a team via chat                       │
│                                              │
│  ACTIVITY                                    │
│  ─────────────────────────────────────────   │
│  Recent actions                         >    │
│                                              │
│  CAPTURE                                     │
│  ─────────────────────────────────────────   │
│  Voice input                       [ on ]   │
│  iCloud Drive mirror               [ on ]   │
│                                              │
│  ABOUT                                       │
│  ─────────────────────────────────────────   │
│  Foundation Models             available    │
│  App version                       1.0      │
│  Export event log                       >   │
│                                              │
└─────────────────────────────────────────────┘
```

- Use `Form` + `Section` with `header:` (uppercase via `.textCase(.uppercase)`).
- Section header copy: literal as shown (TIMING, MODES, LIFE TEAMS, ACTIVITY, CAPTURE, ABOUT).

### 3.2 TIMING

- **Morning brief** → push to `TimePickerView`. Header: **"When should I send the morning brief?"** Body before picker: **"It fires once a day. You can mute it anytime."** Default 07:00.
- **Quiet hours** → push to `QuietHoursView`. Two time pickers (start/end). Header: **"No nudges between these times."** Body: **"The morning brief still fires if it falls outside this window."** Default 22:00–05:00.
- **Max nudges per day** → push to a stepper view. Header: **"How many nudges per day, max?"** Body: **"Includes the morning brief. Default is 3."** Range 1–6. Default 3.
- **Minimum gap between nudges** → push to a stepper. Header: **"Minimum time between nudges?"** Range 30–240 min in 15-min steps. Default 90.

All edits write `settings_json` and emit an event `kind='settings_change'` with the diff in payload.

### 3.3 MODES

**Mercy mode row:**

- Trailing `Toggle`.
- Tap toggle ON → action sheet:
  ```
  Engage mercy mode

  Softer nudges, fewer of them.
  No reviewing gaps.

  For how long?
   • The rest of today
   • 3 days
   • 1 week
   • Until I turn it off
   • Cancel
  ```
- Engaging schedules `mercy_mode.engage(until_when, "user-toggled from Settings")`.
- When ON, row caption beneath the toggle: **"On until {when}. Outkeep is gentler right now."** with a **"Turn off"** affordance.
- Toggle OFF → no confirmation. Emits `mercy_mode.disengage` event.

**Pause row:**

- Same pattern. Action sheet:
  ```
  Pause Outkeep

  All proactive nudges stop.
  Your own calendar/reminder commitments
  still fire — Outkeep just stays quiet.

  For how long?
   • The rest of today
   • Until tomorrow morning
   • 1 week
   • Until I turn it off
   • Cancel
  ```
- When ON, row caption: **"Paused until {when}. Calendar and your own reminders still fire."**

**Forbidden:** no "Are you sure?" warnings on engage. These are mercy-forward features; we make them easy to turn on, not scary.

### 3.4 LIFE TEAMS

- Lists all domains where `archived_at IS NULL`, sorted by `created_at` desc.
- Each row: SF `person.2.fill` in `DomainColor.for(domain)` + `display_name`.
- Tap → `DomainDetailView`:

  ```
  ┌─────────────────────────────────────┐
  │ < Settings    Health team           │
  ├─────────────────────────────────────┤
  │                                     │
  │  NAME                               │
  │  ────────────────────────────────   │
  │  Health team                        │
  │                                     │
  │  ROLE PROMPT                        │
  │  ────────────────────────────────   │
  │  [multiline text editor — full      │
  │   role_prompt, editable]            │
  │                                     │
  │  This is the team's working brief.  │
  │  Edit it like you'd brief a new     │
  │  collaborator.                      │
  │                                     │
  │  INSTRUMENTS                        │
  │  ────────────────────────────────   │
  │  Sleep                          >   │
  │  Weight                         >   │
  │                                     │
  │  ACTIONS                            │
  │  ────────────────────────────────   │
  │  Archive this team                  │
  │                                     │
  └─────────────────────────────────────┘
  ```

  - **Edit name:** inline `TextField`. Save on blur. Emits event.
  - **Edit role prompt:** `TextEditor`, min 8 lines. Saves on blur via `domain.update_prompt`. Helper caption: **"This is the team's working brief. Edit it like you'd brief a new collaborator."**
  - **Instruments list:** each instrument row → push to `InstrumentDetailView` (rename, edit definition, archive).
  - **Archive this team:** red `.destructive` button. Confirmation: **"Archive Health team? Its instruments stop updating. You can still see history."** Buttons: **Archive** / **Cancel**. NO "delete forever" — archive only.

- **+ Add a team via chat** row: full-width tappable row at the bottom of the section. Tapping switches to Chat and posts a system-initiated coordinator message (does NOT auto-send a user message): **"Want to add a new team — what would you like me to help carry? Name and tone are up to you; I'll propose a starting shape."** This guarantees teams are always spawned via chat per spec §16.

### 3.5 ACTIVITY (audit log)

Row: **"Recent actions"** → push to `AuditLogView`.

```
┌─────────────────────────────────────────────┐
│  < Settings    Recent actions               │
├─────────────────────────────────────────────┤
│  TODAY                                       │
│  ─────────────────────────────────────────   │
│                                              │
│  10:42 PM  Health team                       │
│  Updated weight_trend → 178.4                │
│  Why: You logged "weighed 178 this morning." │
│  [ Undo ]                                    │
│                                              │
│  10:30 PM  Outkeep                           │
│  Scheduled "Wind-down nudge" for 22:30       │
│  Why: You asked for a wind-down reminder.    │
│  [ Undo ]                                    │
│                                              │
│  YESTERDAY                                   │
│  ─────────────────────────────────────────   │
│  ...                                         │
└─────────────────────────────────────────────┘
```

- Source: `events` rows where `actor` starts with `agent:` or `actor='coordinator'` AND `kind` is in the externally-mutating set (calendar_*, sheets_*, notification_*, instrument_create, instrument_apply_event, domain_create, memory_save, commitment_create, mercy_mode_engage, pause_engage, quiet_hours_set).
- Pagination: last 50 by default; "Show 50 more" button at bottom.
- Grouped by day (today / yesterday / earlier).
- Each entry shows: time, actor (Outkeep or `{domain} team`), one-line summary, **"Why: {reasoning}"** below, **Undo** button if reversible.
- Undo button behavior:
  - Confirmation alert **"Undo this action? Outkeep will roll it back."** Buttons: **Undo** / **Cancel**.
  - Emits inverse event per spec §15. UI immediately marks the entry with a `.strikethrough()` + small caption **"Undone."** Undo button removed.
  - If undo itself fails: red toast **"Couldn't undo this one. {error}."**
- Empty state: **"Nothing here yet. Outkeep's actions will show up here as they happen."**

### 3.6 CAPTURE

- **Voice input** toggle → writes `voice_capture_enabled` in settings_json. When off, mic icon disappears from Chat input bar.
- **iCloud Drive mirror** toggle → writes `csv_mirror_enabled`. When off, sync queue stops flushing; existing files stay. Caption beneath: **"Mirrors your instruments to {iCloud_path}. Read-only in Numbers unless you edit there."**

### 3.7 ABOUT

- **Foundation Models** status: `available` (green dot), `unavailable` (red dot + tap for explainer), `loading` (spinner). Read-only.
- **App version**: e.g., "1.0 (build 1)". Read-only.
- **Export event log** → push to a view with two buttons:
  - **Export as JSON** (writes a timestamped `.json` to Files via `.fileExporter`)
  - **Export as CSV** (writes per-month CSVs zipped, via `TabularData` + `Compression`)
- Below the export: a single line **"This is your data. Take it anywhere."**

### 3.8 No deferred-feature mentions

Spec §21 deferred items (Google Calendar/Sheets, Apple Health, web search, etc.) **do not appear in Settings at all** in v1. Don't show greyed-out placeholders — that creates "missing feature" feelings. The app is complete on the features it ships.

---

## 4. Tone-of-voice cheat sheet (Implementer reference)

When implementing any copy not explicitly specified here, follow these rules. When in doubt, ship simpler / quieter.

**Do say:**
- "Logged."
- "Done."
- "Got it."
- "When you're ready."
- "No pressure."
- "Tell me what's up."
- "Quiet stretch."
- "Nothing on deck."

**Don't say (banned patterns from spec §15):**
- ~~"Great job!"~~ / ~~"Awesome!"~~ / ~~"You crushed it!"~~ (sycophantic)
- ~~"Let's get back on track."~~ / ~~"Back at it!"~~
- ~~"You missed X days."~~ / ~~"It's been Y days since you…"~~
- ~~"Don't break the streak!"~~ / any streak language
- ~~"You should…"~~ / ~~"You didn't…"~~ / ~~"Try to…"~~
- ~~"Are you sure you want to do that?"~~ for mercy/pause — make it easy to be gentle on yourself
- Emoji in shipped strings unless this spec uses one (it doesn't)

**Default time formats:**
- Times: 12-hour with AM/PM, e.g., "7:00 AM", "10:30 PM". Use `.dateTime.hour().minute()` with current locale.
- Relative dates: "today", "yesterday", "3d ago", "1w ago". Beyond 4 weeks: actual date "Apr 12".

**Pluralization:** always use proper pluralization (`Foundation`'s `AttributedString` / `String.localized(...)`. Never write `"1 nudges"`.

---

## 5. State diagrams (key flows)

### 5.1 Chat turn states

```
idle
  │  user sends
  ▼
sending ─── network not required ──> coordinator_running
                                          │
                       (tool call?)       │
                  ┌──────┴──────┐         │
                  ▼             ▼         │
            tool_executing  handoff_pending
                  │             │         │
                  └─────────────┤         │
                                ▼         ▼
                          (assistant reply)
                                │
                                ▼
                          idle (transcript appended)
```

UI mirrors:
- `idle`: input bar enabled, no thinking indicators.
- `sending`: user bubble appears immediately, optimistic. Send button → spinner for ~200ms.
- `coordinator_running`: "Outkeep" thinking bubble.
- `handoff_pending`: handoff inline indicator → domain agent thinking bubble.
- `tool_executing`: no extra UI; tool-call cards appear after they complete.

### 5.2 Today brief lifecycle

```
on tab appear
  │
  ▼
read last_brief
  │
  ├─ <6h old ───> render existing
  │
  └─ ≥6h old OR null ──> shimmer card ──> coordinator.generate_brief
                                              │
                                  success ────┴──── fail
                                    │              │
                                    ▼              ▼
                              render brief    error caption + retry button
```

### 5.3 Mercy mode toggle

```
[ off ] ── user taps ──> action sheet
                            │ pick duration
                            ▼
                       mercy_mode.engage(until)
                            │ success
                            ▼
                       [ on, "until {when}" ]
                            │ user taps "Turn off"
                            ▼
                       mercy_mode.disengage()
                            │
                            ▼
                       [ off ]
```

---

## 6. Component manifest (for Implementer's file structure)

Suggested SwiftUI view files. Implementer can rename, but the surface area should match:

```
Steward/UI/
├── Root/
│   ├── RootTabView.swift              — TabView with three tabs
│   └── DomainColor.swift              — domain → Color stable mapping
├── Chat/
│   ├── ChatView.swift                 — main chat surface
│   ├── MessageBubble.swift            — user / coordinator / domain styles
│   ├── ToolCallCard.swift             — collapsible inline card
│   ├── HandoffIndicator.swift         — "Handing off to X team…" row
│   ├── ThinkingBubble.swift           — shimmer dots
│   ├── ChatInputBar.swift             — text field + send + mic
│   ├── VoiceRecordingOverlay.swift    — hold-to-talk waveform + states
│   ├── ChatEmptyState.swift           — first-launch greeting
│   └── OfflineBadge.swift
├── Today/
│   ├── TodayView.swift
│   ├── MorningBriefCard.swift
│   ├── DomainSectionHeader.swift
│   ├── InstrumentCard.swift           — value/delta variants per kind
│   ├── InstrumentGridView.swift       — full grid (spec §12 Surface 1)
│   ├── UpcomingList.swift
│   └── TodayEmptyState.swift          — no-domains-yet state
└── Settings/
    ├── SettingsView.swift             — top-level Form
    ├── TimingSection.swift
    ├── ModesSection.swift             — mercy + pause rows
    ├── LifeTeamsSection.swift
    ├── DomainDetailView.swift
    ├── InstrumentDetailView.swift
    ├── AuditLogView.swift
    ├── CaptureSection.swift
    └── AboutSection.swift
```

---

## 7. What grading drift looks like (so Implementer knows)

When team-lead reviews, the following count as drift from this spec and will block ship:

1. Any moralizing or shame copy not in this file ("you've missed", "back on track", streak counts).
2. Empty states that ask the user to set things up via forms instead of routing to chat.
3. Tool-call cards hidden behind a "Show details" button instead of inline + collapsible.
4. Domain agents indistinguishable from coordinator in chat (no color/label difference).
5. Today tab showing pre-seeded example domains/instruments when the user has none.
6. Settings showing deferred features as "coming soon" placeholders.
7. Mercy/pause requiring confirmation friction to engage.
8. Streak language anywhere — including in checklist instruments (use "{N} checked today" never "X days in a row").
9. Hard error states (full-screen error) for any non-fatal condition. Most errors are inline + dismissible.
10. Notification cap or quiet hours hidden in nested screens — they're top-level Settings rows.

---

## 8. What's intentionally NOT in this spec

These are Implementer's call (within taste):

- Animation timing curves (default to `.easeInOut(duration: 0.2)` unless specified).
- Exact pixel padding values not specified (use 8/12/14/16 multiples).
- Haptic feedback frequency beyond the ones called out (use sparingly; `.notificationOccurred(.success)` on send is fine).
- Specific shimmer shader (use `Material` overlay + opacity animation, or any equivalent).
- Pull-to-refresh customization (system default is fine).

If you find yourself wanting to add a screen, modal, or persistent UI element not in this spec, **ask team-lead first**. Scope discipline: build what's here completely, not extra things half-way.

---

**End of spec. Implement deterministically. When tone drifts, re-read sections 1.7, 2.6, and 4.**
