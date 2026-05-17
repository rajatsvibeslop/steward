# Steward UI Rework v1.5 — UX Journey

**Status:** authoritative UX source for v1.5 IA shift. Designer's layout spec and Arch's data-flow analysis depend on this. Supersedes the Chat/Today/Settings tab nav in v1 (`v0.9.6-sunday-morning`).

**What changed (Rajat, 2026-05-17 ~10:45 EDT, verbatim):**
> "I'd like a rework of the UI. I want the *landing* to be an agent page with tabs (for individual workers). Think Authy where there's one coordinator chat box (which if I type into it will open the coordinator chat) and then squares for each task/goal I've spun up. And then there's tabs *inside* the task/goal ones, one for chat, one for giving me view access to the sheet. And of course a global setting toggle but not as a tab. Think about what this means."

---

## 0. User-facing label: **"team"**

Across all v1.5 copy, a domain is rendered as a **team**. Tile labels read **"Sleep team"**, **"Money team"**, **"Home team"**, etc. The empty-state CTA tile reads **"+ Spawn a team"**.

**Why "team" and not agent/worker/goal/tile:**
- Already in shipped copy (ui-specs.md, CoordinatorEmptyStateCopy.swift, spec.md) — switching costs effort with no UX gain
- Conveys "they work for you," which inverts the "I'm failing at my system" framing this user explicitly rejects
- The coordinator agent already says **"I'll call this the {Team Name} team"** during onboarding — keep it stable
- "Agent" is technical; "worker" is awkward in copy ("the Sleep worker"); "goal" loads moralization; "tile" is UI jargon

The coordinator should still **understand** any of these terms when the user types them ("spawn me a Money agent" / "add a new worker"), but the rendered label is always "team."

---

## 1. Mental model — what is a tile?

A tile is **a worker plus its workspace**. Tapping a tile is "going to that worker's desk." On the desk are two things: a chat box (talk to the worker) and a sheet (look at the worker's books). That's it. The worker is its own surface; the coordinator stays on the landing page.

**The Authy mapping:**

| Authy | Steward v1.5 |
|---|---|
| Account row (Google, Slack, etc.) | Team tile (Sleep team, Money team, etc.) |
| 6-digit code = "the current value" | Primary instrument value on tile face |
| Countdown ring = "freshness" | "Logged Nh ago" subtext on tile face |
| Tap a row → expanded detail | Tap a tile → tile detail with Chat / Sheet sub-tabs |
| Search bar at top | **Coordinator chat box** at top |
| `+` button | **"+ Spawn a team"** CTA tile (last grid position) |
| Gear icon top-right | Gear icon top-right (Settings modal) |

**What a tap on a tile implies (user expectation):**

> "I'm switching contexts to focus on this one team. The coordinator isn't in this room. The worker here only knows this team's stuff. If I want a cross-team answer, I back out to the landing and ask Outkeep."

This expectation is the load-bearing constraint that resolves nearly every contested decision below.

---

## 2. Resolved decisions

### 2.1 Conversation threading — **per-team threads**

Each team tile owns its own conversation thread, partitioned by the existing `events.domain` column (per Arch's Option A — no migration). The coordinator's landing chat is its own thread (`domain IS NULL`). Threads do not merge.

**What the coordinator knows about what was said inside a team tile:** **nothing, directly.** The coordinator never reads raw team-tile transcripts as context. Instead:

- The coordinator sees the **event log** (always has — events are logged regardless of which thread originated them). If the user told the Sleep agent in its tile "slept 6h, cat woke me at 4," the `event.capture` tool wrote that to events with `domain='health'`. Coordinator's `event.list(domain:'health')` reads it.
- The coordinator sees **memory items** the domain agent chose to admit (per spec §9 admission control). If the Sleep agent decided "user has a cat-waking pattern at 4am" is a durable observation, it called `memory.save(type='observation', domain='health')`. Coordinator's hybrid retrieval surfaces it on relevant queries.
- The coordinator does **not** see chit-chat or unproductive turns inside a team tile.

**Why this works:**
- It enforces the right write-path discipline (durable facts → memory; events → event log). This is already spec §9 — v1.5 just makes the boundary visible through IA.
- It keeps the coordinator's context budget tight (no transcript bloat from 6 teams' chats).
- It matches the user's "the worker has its own desk" mental model.
- Cross-domain queries still work via `agent.handoff` — coordinator spawns a domain agent session per team it needs to ask, and synthesizes in the final reply. (`agent.cross_consult` is **v1.6**, not v1.5 — Arch's call per Appendix C of the impact doc. For v1.5, multi-team synthesis is N sequential handoffs in the coordinator's existing tool loop.)

**Schema impact (resolved by Arch):** zero migration. Arch's `ui-rework-v1.5-arch-impact.md` confirms the existing `events.domain` column carries the partitioning. Coordinator chat reads `WHERE domain IS NULL`; tile chat reads `WHERE domain = ?`. See §2.7 for the exact rendering semantics.

### 2.2 Tile face — **team name + primary instrument value + freshness**

One face per tile. Three elements only:

1. **Team name** ("Sleep team") — top, `.headline`, in the team's color (existing `DomainColor.for(domain:)`).
2. **Primary instrument value** ("6.2h" / "$184 left this week" / "3/5 done today") — center, large, `.title2.monospaced`. The primary instrument is:
   - The instrument with the most recent activity, OR
   - User-pinned (later v1.5.x; not v1.5.0)
   - If the team has zero instruments yet: render **"No tracks yet — tap to add one."** in `.callout`, centered.
3. **Freshness subtext** ("logged 2h ago" / "logged 3d ago" / "not yet today") — bottom, `.caption2`, `.secondaryLabel`. Never says "missed" or "overdue."

**Optional 4th element (unread-activity dot):** small filled circle, top-right corner, accent color. Lights up only when the team's agent did something the user hasn't seen — a new proposal in the team chat, a completed scheduled task with a note, a CSV mirror conflict the user should know about. **It NEVER lights up for "you missed N days."** Lapses are not notifications. Once the user opens the tile, the dot clears.

**Justification for "primary instrument value" as the one signal:**
- The user opens the app to either (a) capture something or (b) check on something. The face answers (b) at-a-glance, with one number per team. (a) is served by the coordinator chat box.
- Authy works because the code is the answer — you don't have to enter the row to know your code is `483 192`. Steward's analog should work the same way.
- A sparkline would compete with the number; a badge would create shame surface; "domain name only" wastes the glance.

**Rejected alternatives:**
- Sparkline trend line: too much visual noise across 6+ tiles
- Stoplight color (green/yellow/red): moralization surface
- "Last action by agent" text: too vague to act on at a glance

### 2.3 Coordinator's domain handoff — **kept, with visible routing**

The legacy v1 `agent.handoff(domain, message)` tool stays in coordinator scope. When the user types in the **landing coordinator chat box** "slept 6h," the coordinator does exactly what it does today: hands off to the Health team's agent, the agent calls `event.capture`, instrument updates, coordinator returns a synthesized reply.

**Why keep it:** removing handoff forces the user to navigate to the right tile before they can dump something. That's friction reintroduced exactly where v1's lit-review-grounded low-friction-capture principle was protecting against.

**UI requirement (Designer):** the coordinator chat must still render the handoff visually using the existing `HandoffIndicator` + `DomainBubble` components (already in `Views/Chat/`). When a handoff happens, the user sees "Handed to Sleep team" → Sleep team's reply inline. Same component code as v1; just lives in coordinator chat thread now.

**What's different from v1:** in v1, all chat happened in one thread, so a handoff was a stylistic distinction within one transcript. In v1.5, the **landing coordinator chat** is the only thread where handoffs are visible — once the user enters a team tile, that tile's chat is a direct 1:1 with the domain agent, no handoffs, no coordinator presence.

### 2.4 Sheet tab content — **all instruments for the team, as grids; events expandable below**

The Sheet tab inside a tile shows:

1. **Header strip** — team name + last-updated timestamp + "+ Add a track" button (opens an inline prompt that routes to the in-tile domain chat: "I'd like another track here.").
2. **One section per instrument**, in order of most-recently-updated:
   - Section header: instrument name + kind label (e.g. "Sleep · 7-day rolling average") + collapse/expand chevron.
   - Body: the existing spec §12.1 in-app spreadsheet grid (header row from `definition_json`, data rows from `state_json` + events, computed-values footer with rolling aggregates).
   - All instruments expanded by default if ≤3 instruments; collapsed-by-default with header summary if ≥4.
3. **"All events" disclosure at the bottom** — collapsed by default. Expand → reverse-chronological list of events for this domain (filtered from the events table). This is the raw audit lane.

**Why this and not sub-tabs:** landing → tile (level 1) → Chat / Sheet sub-tab (level 2) → instruments / events sub-tab (level 3) is one level too many. Stacking instruments + an events disclosure inside one Sheet tab keeps it at two navigation levels.

**Rejected alternatives:**
- Sheet shows only events: the user explicitly said "view access to the sheet" (singular) but means *the spreadsheets they understand from spec §12* — i.e. instrument grids, not raw event tables.
- Sheet shows only one (the primary) instrument: hides multi-instrument teams. The Money team will plausibly have a weekly-discretionary instrument AND a monthly-rent-budget instrument; both need to be visible.
- Sheet has an events sub-tab: see "two navigation levels" justification.

### 2.5 Spawning new teams — **always through coordinator chat, two entry points**

Spawning routes:

| Entry point | Behavior |
|---|---|
| User types in coordinator chat: "spawn me a Money agent" / "add a new team for hobbies" | Coordinator runs the same Branch B flow from `CoordinatorEmptyStateCopy.swift` (the empty-state-script-but-for-Nth-team). Reuses copy templates verbatim. |
| User taps the **"+ Spawn a team"** CTA tile (always the last position in the landing grid) | Opens the coordinator chat with a pre-seeded coordinator bubble: **"Want to add a new team — what would you like me to help carry? Name and tone are up to you; I'll propose a starting shape."** (Replaces the existing v1 ui-specs.md L614 string.) **Does NOT auto-send a user message.** The user types their answer; the coordinator runs Branch B from B1 onward. |

**Both paths land in `CoordinatorEmptyStateCopy` Branch B — the script that already exists.** No new branching logic required. The only addition is the "+" tile as a UI affordance.

**What's explicitly rejected:** a "Create Team" modal form with name + role-prompt + instrument fields. Spec §2 #9 ("domains are runtime config, not hard-coded code paths") + spec §16 (always through chat) are invariant. A form would reintroduce exactly the quiz energy the v2 script banned.

### 2.6 Cross-domain queries — **coordinator handles, domain tiles deflect**

User asks "what's affecting my sleep?":

- **In the coordinator chat box on landing:** coordinator uses `agent.handoff(domain: 'health', message: '...')` once per team it needs to ask, gets each domain agent's reply as a tool result, and synthesizes the final answer in landing chat. For v1.5, this is N sequential handoffs within the coordinator's existing turn loop (`agent.cross_consult` — a lighter-weight read-only variant that would skip the handoff overhead — is **v1.6**, deferred per Arch). Functionally unchanged from the user's perspective; just slower when many teams are involved.
- **Inside a team tile chat (say the Money tile):** the Money agent recognizes the question is out-of-scope and replies with a verbatim deflection:

  > **"That's a cross-team question — I only know about Money. Back out and ask Outkeep on the landing page, or rephrase it as a Money question."**

  Optional one-tap chip: `Take this to Outkeep` — tapping copies the user's question into the coordinator chat draft and switches to landing. Coordinator chat draft is pre-filled; user hits send.

**Why this works:** the user gets routed correctly without losing what they typed, and the domain agent never tries to reason cross-domain (which it has no context for).

### 2.7 Conversation locality — **chat threads do not mirror; the event log does the bridging**

This is the load-bearing answer to "where does a conversation live?" The wrong answer here makes every other decision in §2 incoherent.

**Question 1.** When the user is in the landing **coordinator chat** and the coordinator hands off to (say) the Sleep agent, where does Sleep's reply appear?

**Decision: (a) — landing coordinator chat only.** The Sleep agent's reply is a turn in the *coordinator-chat thread*, rendered as a `DomainBubble` (existing v1 component) with the "Sleep team" label so the user sees whose voice it is. **It does NOT also appear in the Sleep tile's Chat tab.**

**Question 2.** When the user is **inside a tile's Chat** and talks to that domain agent, does the exchange appear anywhere else?

**Decision: no.** Tile chat is single-domain and stays single-domain. The coordinator's landing chat is `WHERE domain IS NULL` and never shows tile-chat content.

**Reasoning** (this is where team-lead's instinct toward (c) needs the pushback):

1. **A chat thread is a context-bearing back-and-forth, not an archive.** If the user asks the coordinator "how's sleep this week?" and Sleep replies "6.2h avg, down from 6.8 last week," that *reply only makes sense in the context of the user's question*. The question is in coordinator chat. Replaying just the reply in Sleep tile chat strips it from context — the user opens Sleep tile next morning and sees "6.2h avg, down from 6.8 last week" hanging in the air with no question above it. That's worse, not better.

2. **The Authy analog cuts the other way on chat.** Authy duplicates *current state* (the 6-digit code) across the grid and the account tile. Steward already does this — the primary instrument value is on the tile face AND in the Sheet tab grid. **But Authy has no conversations to duplicate.** Chat turns aren't like state values; they're turns in a thread.

3. **The "I want to see all of Sleep agent's history" intuition is real, and is satisfied by a different surface.** The Sheet tab's "All events" disclosure (§2.4) is filtered `WHERE domain = ?` and shows every state mutation Sleep has done — `instrument_apply_event`, `notification_scheduled`, `commitment_create`, all of it — **regardless of which chat thread originated the request.** That IS the unified Sleep-agent audit lane. It's the right surface for "what's Sleep agent been up to," because it's filterable, sortable, and doesn't depend on the user remembering which thread they were in.

4. **Avoids the synchronization rabbit hole.** If we mirrored chat turns into tile chat, we'd also have to answer: if the user *replies* to a mirrored Sleep bubble inside the tile chat, does that reply jump back into coordinator chat? Does Sleep agent in the tile session have context from the coordinator session? Every answer here is either (a) confusing or (b) requires bridging session context between threads, which contradicts the per-team-thread isolation in §2.1.

**The implementation contract** (for Arch's Option A schema):

| Where the user typed | Resulting events row(s) | Visible in coordinator chat (`domain IS NULL`) | Visible in Sleep tile chat (`domain = 'health'`) | Visible in Sleep tile Sheet > All events (`domain = 'health'`, non-chat kinds) |
|---|---|---|---|---|
| Coordinator chat, no handoff needed (e.g., "set mercy mode for 3 days") | `actor='user', domain=NULL, kind='chat_turn'` + coordinator reply `actor='coordinator', domain=NULL, kind='agent_reply'` | yes | no | no |
| Coordinator chat, handoff to Sleep ("how's sleep?") | `actor='user', domain=NULL, kind='chat_turn'` + Sleep's reply `actor='agent:health', domain=NULL, kind='agent_reply'` (threads with the question) + any tool calls Sleep made `domain='health', kind='instrument_read'` etc. | yes (user message + Sleep's reply rendered as DomainBubble) | no (Sleep's reply has `domain=NULL`) | yes (the tool calls have `domain='health'`) |
| Sleep tile chat ("took a 40 min nap") | `actor='user', domain='health', kind='chat_turn'` + Sleep's reply `actor='agent:health', domain='health', kind='agent_reply'` + tool calls `domain='health'` | no | yes | yes (tool calls) |

The key insight encoded above: **chat turns get the `domain` of where the user typed them, not the agent who replied.** A handoff reply is a chat turn in coordinator chat because the user's originating message is in coordinator chat. The per-domain audit lane (Sheet tab events disclosure) reads non-chat kinds — `instrument_apply_event`, `notification_scheduled`, `instrument_create`, `commitment_create`, `agent_action`, etc. Those reflect "what the agent DID to my state," which is what the user wants in an audit lane.

**This aligns with Arch's lean** (`ui-rework-v1.5-arch-impact.md` Appendix B #1) and Arch's `EventLog.insertChatTurn(actor:domain:text:turnID:)` chokepoint enforces it: tile chats can't accidentally write `domain=NULL` and leak into coordinator chat. The chat-surface side of the contract is now nailed; the audit-lane side requires the Sheet tab's events disclosure to filter on `kind NOT IN ('chat_turn', 'agent_reply')` so chat content doesn't pollute the state-mutation audit view.

**One edge case worth naming.** A user might want to "go to where the Sleep agent said that thing about my caffeine cutoff." If that exchange happened via coordinator handoff, it lives only in coordinator chat — the user has to scroll there. If it happened in tile chat, only in tile chat. For v1.5.0, accept this; the Sheet tab's events disclosure is the durable audit surface, and chat is a transient conversational surface. If dogfooding shows the user actually does want "all Sleep agent's words across all threads," v1.6 can add a tile-Chat-tab disclosure ("Recent activity via Outkeep — N replies in coordinator chat in the last 7 days · tap to view") that links over to coordinator chat with the relevant turns scrolled into view. **Do not build this in v1.5.0** — it's the kind of UX feature that should follow real friction signal, not anticipated friction.

---

## 3. Primary user journeys (end-to-end)

### 3.1 Cold launch, zero teams → first team spawned

1. User opens app fresh (no prior session; install was earlier today or last night).
2. App bootstraps. Foundation Models cold-warms in background per v1 splash.
3. Landing view renders. Layout:
   - Top: coordinator chat box (collapsed, single-line). Placeholder: **"Tell me what's on your mind, or hold the mic to talk."**
   - Center: empty grid with ONE tile — the **"+ Spawn a team"** CTA tile, full-size, accent-colored border, sparkle icon, label **"+ Spawn a team"** + subtext **"This is where your teams live. Tap to start."**
   - Bottom-right: gear icon (Settings modal entry).
4. User has two natural moves:
   - **Move A** — tap the coordinator chat box: opens full coordinator chat. Greeting per `CoordinatorEmptyStateCopy.greeting(forLocalHour:)`. Empty-state branching per v2 script runs as before. After Branch B exit, user is back on landing; new tile has appeared next to the "+" tile.
   - **Move B** — tap the "+ Spawn a team" tile: opens coordinator chat with pre-seeded coordinator bubble (per §2.5 above). User answers, Branch B runs, exit to landing with new tile.

**The greeting bubble** (UI-rendered, not LLM-emitted) is shown in coordinator chat regardless of entry point — it's the v1.1 greeting from `CoordinatorEmptyStateCopy`, unchanged. Empty-state chips (`Catch something`, `Walk me through it`) also unchanged.

**Acceptance:** by end of journey, user has 1 team tile visible on landing, primary instrument value showing, and is back on the landing surface.

### 3.2 Cold launch, N teams (steady state) → tap a tile to log → return to landing

1. User opens app at 14:30 (afternoon, not coming from a notification). Has 3 teams: Sleep, Money, Home.
2. Landing renders:
   - Coordinator chat box at top. Placeholder: **"Tell me what's on your mind, or hold the mic to talk."** (No fresh morning brief — it's afternoon.)
   - Grid: Sleep tile (showing "6.2h · logged 7h ago"), Money tile ("$184 left this week · logged 1d ago"), Home tile ("2/3 done today · logged 3h ago"), "+ Spawn a team" tile.
   - Gear top-right.
3. User taps **Sleep tile** because they want to log a nap.
4. Tile detail view slides in. Layout:
   - Top: tile header — back chevron + "Sleep team" + team-color stripe + gear-secondary icon (team-scoped settings: rename, change tone, archive).
   - Sub-tab bar: **Chat | Sheet** (Chat selected by default if the user has never opened this tile OR if there's unread agent activity; otherwise restore last-selected per tile).
   - Body: Chat sub-tab content — direct conversation with the Sleep agent. No coordinator presence. Input bar at bottom (same `ChatInputBar` component, same voice mic).
5. User types: "took a 40-min nap"
6. Sleep agent (running with its scoped tool set, `agent.handoff` NOT in scope) calls `event.capture(domain='health', text='nap, 40 min')` and updates the sleep-related instrument(s) per its own logic. Replies in tile chat: **"Logged — 40 min nap."**
7. User taps back chevron. Returns to landing. Sleep tile face has updated (or is in the process of updating — show a brief skeleton-flash on the value while state recomputes).

**Acceptance:** capture inside a team tile produces the same event-log entry as capture via coordinator handoff. State updates regardless of entry point.

### 3.3 Notification arrives → tap → lands inside that team's Chat

1. 22:30 — wind-down notification fires. Title: "Wind-down". Body: "Want to close out the day?" `NotificationActionContext.kind = .windDown`, `domain = 'health'`, `suggestedPrompt = "Want me to log your wind-down? Sleep window starts soon."`
2. User taps the banner.
3. `NotificationActionRouter` decodes the typed `NotificationActionContext` (already implemented in `NotificationActionRouter.swift`).
4. App launches/foregrounds. `RootView` (replaces `RootTabView`) reads the buffered tap event from `NotificationActionRouter.shared.takeLastTapEvent()` per the existing cold-launch buffer drain pattern.
5. **NEW BEHAVIOR (v1.5):** if `tapEvent.routed.domain != nil`, navigate directly to that team's tile, select the **Chat** sub-tab, and inject the `suggestedPrompt` as a coordinator-initiated bubble (treated as if Steward herself sent it — same `CoordinatorBubble` rendering as the v1 flow, just inside the team-tile chat thread).
6. If `tapEvent.routed.domain == nil` (morning brief, generic notification): land on landing → open coordinator chat → inject prompt there.
7. If `tapEvent.malformed`: land on landing, then surface a `SystemNoteRow` in coordinator chat **"A notification's context didn't load. Tap to open Outkeep as usual."** (same anti-silent-fallback discipline from v1).

**Schema confirmation (Arch):** `NotificationActionContext.domain` already exists (line 39 of `NotificationActionRouter.swift`). No new fields needed. The router just dispatches differently in v1.5.

**Acceptance:** every tap on a domain-scoped notification lands the user one tap deeper than v1 (skip-the-coordinator-chat-intermediate-step) without losing the suggested-prompt injection.

### 3.4 Morning brief at 7am → user opens app → where does the brief appear?

1. 07:00 — morning brief notification fires. Generated body included a 2–3 sentence summary. `NotificationActionContext.kind = .morningBrief`, `domain = nil`.
2. **Scenario A — user taps the notification:** lands on landing, then opens coordinator chat with the brief rendered as the most recent coordinator bubble (using the existing `MorningBriefCard` or — preferred — a simple `CoordinatorBubble`; see §5 friction notes).
3. **Scenario B — user opens app without tapping** (notification was on lock screen, user opened from Springboard):
   - Landing renders normally.
   - Coordinator chat box at top **shows brief preview instead of placeholder text.** Preview format: first 2 lines of the brief body, italic, accent-tinted left border. Format: **"This morning · 6.2h sleep, weight steady. Tap to read the full brief."**
   - The preview is shown when: `latestBrief.generatedAt > now - 6h` AND `latestBrief.acknowledged == false`. Once the user opens the coordinator chat (or explicitly dismisses with a small × on the preview), the preview clears and reverts to the placeholder.
   - **No banner.** No full-takeover. The brief stays available without obstructing the grid.

**Where the brief is NOT shown:**
- It's not duplicated inside any team tile.
- It's not a separate sticky "Today" surface — the v1 Today tab is gone, and its content (brief, upcoming, instruments) is redistributed across coordinator chat box + tile faces + Up-Next strip (see §5.3).

**Acceptance:** the brief is one tap away from any landing entry, and never invisible after a tap-less open.

**Motto in brief footer? No.** The new product motto ("Structure your life. Make better choices.") lives on the **onboarding splash only** — not in any recurring surface. The morning brief fires every day; a slogan on every brief becomes wallpaper after day 3, and "Make better choices" leans imperative enough that repeated daily delivery would read as exactly the kind of low-grade moralization v1's anti-moralization rules ban. The brief's anchor is its own calm content ("Here's what's queued for 7am"); the brand voice is in the calmness, not in a slogan reminder. Designer should keep the motto out of brief headers, brief footers, system-note rows, and notification bodies. Splash on first launch is fine — a one-time positioning statement, not a daily nudge.

### 3.5 User wants this week's sleep average → exact path

User intent: "what's my sleep average this week?"

**Path A (via landing tile face — fastest):** glance at the Sleep tile face. If the primary instrument IS the 7-day rolling average, the answer is already on screen. Zero taps. This is the at-a-glance value of the grid.

**Path B (via Sheet tab — for detail):**
1. Tap Sleep tile.
2. Sub-tab defaults to Chat OR last-selected. If Chat: tap **Sheet** sub-tab.
3. Sleep team's instruments stack visible. The "7-day rolling average" instrument's section shows: header value (the current average), the computed-values footer (window values, last_event_at), and the data rows. User reads.

**Path C (via team-tile chat — natural language):**
1. Tap Sleep tile.
2. In Chat sub-tab, type: "what's my average this week?"
3. Sleep agent calls `instrument.read(...)` and replies with the value. (LLM cannot do arithmetic on instrument state — it reads the deterministic value per spec §6.)

**Path D (via coordinator chat — for cross-team context):**
1. Tap coordinator chat box on landing.
2. Type: "how's sleep this week vs. last?"
3. Coordinator calls `agent.handoff(domain: 'health', message: 'how's sleep this week vs. last?')`, Sleep agent reads instrument and replies with the comparison, coordinator synthesizes in the landing-chat reply. (For a single-team query like this, handoff is fine; the v1.6 `agent.cross_consult` optimization matters only when synthesizing across multiple teams in one turn.)

**Acceptance:** the four paths exist and don't interfere. Path A is the dominant one and justifies §2.2's "primary instrument value on face."

---

## 4. Friction risks — what does the new shape *break* that v1's tab nav handled well?

### 4.1 The Today tab as a passive surface

**v1 strength:** open app → Today tab → see brief + active instruments + upcoming, all without engaging chat. A truly passive surface for the "just check on me" use case.

**v1.5 risk:** if a user opens the app intending to passively glance, the landing must be passive too. If tiles' faces don't carry meaningful state (just a name + sparkle), the surface fails the use case.

**Mitigation (already in §2.2):** tile faces show primary instrument value + freshness. The Up-Next strip (§5.3) shows the next 1–2 commitments/notifications. Coordinator chat preview shows the brief when fresh. **The landing is the new Today — and it's more dense per pixel.**

### 4.2 Morning brief discoverability

**v1 strength:** brief was a card at the top of Today tab. Hard to miss.

**v1.5 risk:** brief as a preview inside the coordinator chat box's placeholder is subtler. A user could scroll past it.

**Mitigation:** brief preview takes a full 3 lines (not 1), uses accent-tinted left border, italic, and replaces (not appends to) the chat box's placeholder for the duration. Subtle but visible. If after 1 week of dogfooding Rajat reports missing briefs, escalate to a small "● new brief" pip on the coordinator chat box.

### 4.3 Upcoming commitments / notifications

**v1 strength:** Today tab's "Upcoming" section showed the next 24h of commitments + notifications, dismissable.

**v1.5 risk:** there's no obvious home for this in the new IA.

**Mitigation:** add an **"Up next" strip** on landing, between the coordinator chat box and the team grid. Compact horizontal row (or 2 lines max) showing the next 1–2 commitments/notifications. Tapping a commitment opens its existing detail sheet (unchanged from v1). Tapping a notification opens the team tile it's scoped to (or coordinator chat if no domain). **Hidden entirely when there's nothing in the next 12h** — no "Nothing on deck" placeholder; let it disappear.

### 4.4 Settings as a tab vs. modal

**v1 strength:** Settings was a tab; navigating to it didn't require modal context. Audit log felt like a real surface.

**v1.5 risk:** deep settings (audit log, mercy mode, per-domain configuration) feel cramped in a modal.

**Mitigation:** gear icon → full-screen modal cover (not a sheet), with its own internal NavigationStack. Audit log can push as a detail view inside the modal. Closing the modal returns to landing with state preserved. Modal can be dismissed by swipe-down from any screen depth.

**Per-team settings** (rename, change tone, archive) live behind a secondary gear icon **inside the team tile header**, NOT in global Settings. This prevents "global Settings has to enumerate all teams' settings" sprawl.

### 4.5 Wrong-room captures

**v1 strength:** one chat. Anything you typed went somewhere sensible because coordinator routed.

**v1.5 risk:** user types "spent $80 on groceries" inside the Sleep tile chat. Sleep agent has no business handling it.

**Mitigation:** domain agents' system prompts must include a one-line graceful-handling clause: **"If the user logs something outside your domain, do not log it. Reply: 'That's a {guessed_domain} thing — I only know about {your_domain_name}. Want me to ping the {guessed_domain} team, or paste it in the Outkeep chat?'"** Offer a one-tap chip `Take this to Outkeep` that copies the message into coordinator chat draft. The Sleep agent never silently captures out-of-scope events.

### 4.6 Coordinator chat's reduced surface

**v1 strength:** the coordinator chat was the conversational center; all turns were there.

**v1.5 risk:** the coordinator chat becomes a thin "router" surface that the user rarely visits, which weakens cross-domain reasoning (which is the coordinator's superpower).

**Mitigation:** explicitly preserve the coordinator's role for:
- Cross-team questions (§2.6)
- Brief generation (§3.4)
- Spawning new teams (§2.5)
- Any message the user types without first entering a tile (§2.3, handoff still kept)

If anything, the coordinator becomes **easier** to invoke — it's at the top of landing, one tap into chat-box-expanded.

### 4.7 The "+ Spawn a team" tile vs. an Add button

**Risk:** tiles in a grid usually represent things-that-exist. A "+ Spawn a team" tile in the same visual language might be confusing or look like a real team.

**Mitigation:** visual treatment is distinctly different — dashed border instead of solid, sparkle icon instead of team color, lighter background. Reads as "an empty slot," not as a real worker. Always last position in the grid order so it's a stable anchor.

---

## 5. Notes for Designer + Arch handoff

### 5.1 Landing layout (one screen, top to bottom)

```
┌─────────────────────────────────────────────┐
│  Outkeep                              ⚙      │   ← gear opens Settings modal
├─────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────┐│
│  │ 🎙  Tell me what's on your mind…       ││   ← collapsed coordinator chat box;
│  │     OR  ► This morning · 6.2h sleep,   ││     placeholder OR brief preview
│  │           weight steady. Tap to read.  ││
│  └─────────────────────────────────────────┘│
│                                              │
│  ─── Up next (10:30 wind-down · 14:00 call mom) ──   ← hidden if empty
│                                              │
│  ┌──────┐  ┌──────┐                         │
│  │ Sleep │  │ Money│                         │
│  │ team  │  │ team │                         │
│  │ 6.2h  │  │$184  │                         │
│  │ 7h ago│  │1d ago│                         │
│  └──────┘  └──────┘                         │
│                                              │
│  ┌──────┐  ┌╌╌╌╌╌╌┐                         │
│  │ Home  │  │  +   │                         │
│  │ team  │  │spawn │                         │
│  │ 2/3   │  │a team│                         │
│  │ 3h ago│  │      │                         │
│  └──────┘  └╌╌╌╌╌╌┘                         │
│                                              │
└─────────────────────────────────────────────┘
```

2-column grid on iPhone; 3- or 4-column on iPad (defer iPad to v1.6).

### 5.2 Tile detail layout (after tap)

```
┌─────────────────────────────────────────────┐
│  ← Sleep team                            ⚙   │   ← back; team gear (per-team settings)
│  ━━━━━━━━━━━━ (team color stripe) ━━━━━━━━  │
├─────────────────────────────────────────────┤
│  [ Chat ]  [ Sheet ]                         │   ← sub-tab bar
├─────────────────────────────────────────────┤
│                                              │
│  (Chat sub-tab body OR Sheet sub-tab body)  │
│                                              │
│  …                                           │
│                                              │
├─────────────────────────────────────────────┤
│  [ 🎙  Type or hold mic…      ] [ → ]       │   ← input bar (Chat only)
└─────────────────────────────────────────────┘
```

Sub-tab bar persists; switching sub-tabs preserves Chat draft if any.

### 5.3 Up-Next strip rules

- Source: `commitments WHERE status='active' AND due_at <= now + 12h` UNION `notifications WHERE delivered_at IS NULL AND scheduled_for <= now + 12h`, sorted by time.
- Show top 2 items as inline chips.
- Each chip: `HH:mm` + short label, ≤24 chars truncated.
- Tap a notification chip → open the team tile its `domain` points to, Chat sub-tab. (Same logic as notification deep-link.)
- Tap a commitment chip → existing v1 commitment detail sheet (unchanged).
- Hidden entirely if 0 items.

### 5.4 Arch convergence (resolved — see Arch's impact doc)

Arch's `spec/ui-rework-v1.5-arch-impact.md` answers the prior open questions; reproducing the takeaways here so Designer + Implementation Pod don't have to cross-reference:

- **Conversation partitioning**: existing `events.domain` column. Coordinator chat = `WHERE domain IS NULL`, tile chat = `WHERE domain = ?`. No new column, no migration.
- **Chat-turn writes**: go through Arch's new `EventLog.insertChatTurn(actor:domain:text:turnID:)` chokepoint so tile chats can't accidentally write `domain=NULL` and leak into coordinator chat.
- **ChatViewModel scoping**: `@StateObject ChatViewModel(thread: .domain(d))` per tile + one `ChatViewModel(thread: .coordinator)` for landing. VM lifecycle = view lifecycle.
- **Coordinator-handoff reply visibility**: lives in coordinator chat only (per §2.7 above). Tool calls Sleep agent makes during the handoff are visible in Sleep tile's Sheet > All events because they carry `domain='health'`.
- **Sheet tab events disclosure**: filter `WHERE domain = ? AND kind NOT IN ('chat_turn', 'agent_reply')` so chat turns don't pollute the state-mutation audit lane.
- **Domain agent scope**: `agent.handoff` is NOT in domain `ToolScope` (already true per `AgentLoop.swift` line 471). v1.5 inherits this constraint naturally — domain agents can't recurse into other domains.
- **NotificationActionRouter dispatch**: `RootView` (new) reads `context.domain` and routes accordingly. Existing `domain` field on `NotificationActionContext` already supports this. No schema change.
- **Out-of-scope deflection copy** (new clause for domain agents per §4.5): add to `RolePromptTemplates.swift`. Templates own the verbatim deflection sentence; the LLM substitutes `{guessed_domain}` and `{your_domain_name}`.

### 5.5 Surfaces that move

| v1 surface | v1.5 destination |
|---|---|
| Chat tab → coordinator chat | Landing coordinator chat box → tap to expand into full coordinator chat |
| Today tab → morning brief card | Brief preview in landing coordinator chat box; full brief in coordinator chat thread |
| Today tab → instrument cards per domain | Team tile faces (primary instrument value); full instrument grids in tile Sheet sub-tab |
| Today tab → Upcoming list | Up-Next strip on landing |
| Settings tab | Gear-icon modal cover from landing |
| Settings → domain detail | Team-tile header secondary gear → per-team settings inside the tile |
| Settings → audit log | Push inside Settings modal (unchanged content) |
| Settings → "+ Add a team via chat" row | "+ Spawn a team" tile on landing (same pre-seeded message) |

### 5.6 Copy strings — literal block for Implementer

All v1.5 user-facing strings collected here. **Verbatim.** Designer hands this to Implementer; Implementer puts each in the file/component noted. No paraphrasing.

#### 5.6.1 Landing surface (new in v1.5)

| String key | Surface | Verbatim copy | Treatment |
|---|---|---|---|
| `landing.appBar.title` | Nav-bar title on the landing screen | `Outkeep` | `.large` title style (system default) |
| `splash.motto` | Onboarding splash, below the app icon, one-time first-launch surface | `Structure your life. Make better choices.` | `.title3.semibold`, centered, `.label`. Shown on first-launch splash only. **Not** repeated in brief headers, brief footers, notification bodies, or system notes (see §3.4 rationale). |
| `landing.coordinatorChatBox.placeholder` | Coordinator chat box on landing, idle state | `Tell me what's on your mind, or hold the mic to talk.` | Single line, `.secondaryLabel` |
| `landing.coordinatorChatBox.briefPreview.format` | Coordinator chat box when a fresh morning brief exists (replaces the placeholder) | `This morning · {brief_first_sentence}. Tap to read the full brief.` | Italic. Accent-tinted 2pt left border. `{brief_first_sentence}` is the first sentence of the generated brief body, truncated to 80 chars with an ellipsis if needed. Shown when `latestBrief.generatedAt > now − 6h` AND `latestBrief.acknowledged == false`. Clears once the user opens coordinator chat OR taps the small × on the preview. |
| `landing.upNext.label` | Up-Next strip header (above the chips) | `Up next` | `.caption.uppercase`, `.secondaryLabel`, 8pt below coordinator chat box. |
| `landing.upNext.chip.format` | Each chip in the Up-Next strip | `{HH:mm} · {short_label}` | Examples: `10:30 · Wind-down`, `14:00 · Call mom`. Truncate `short_label` to 24 chars. |
| Up-Next strip state behavior | (not a copy string — render rule) | **0 items** in next 12h: hide the entire strip (header + chips). No placeholder. **1 item**: render header + one chip. **N items (N≥2)**: render header + first two chips only, in time order. No "+N more" affordance — extra items become visible after the user clears earlier ones or scrolls into a tile. | This is intentional: the strip is a glance surface, not a calendar. If the user needs the full upcoming list they go to the relevant tile (notification → tile chat per §3.3) or to the global notifications list inside Settings. |
| `landing.spawnTile.label` | The "+ Spawn a team" CTA tile (always last grid position) | `+ Spawn a team` | `.headline`, accent color |
| `landing.spawnTile.subtitle` | Subtext on the spawn tile (zero-teams state only) | `This is where your teams live. Tap to start.` | `.callout`, `.secondaryLabel`, centered. Hidden once at least 1 team exists — the spawn tile then shows label only. |
| `landing.spawnTile.coordinatorSeededMessage` | Coordinator-initiated bubble injected when the user taps the spawn tile (pre-fills coordinator chat with this as the most recent coordinator bubble; user types reply) | `Want to add a new team — what would you like me to help carry? Name and tone are up to you; I'll propose a starting shape.` | Same `CoordinatorBubble` rendering as any other coordinator turn |

#### 5.6.2 Team tile (new in v1.5)

| String key | Surface | Verbatim copy | Treatment |
|---|---|---|---|
| `tile.face.teamNameSuffix` | Tile face — appended to the team's display name | ` team` | E.g., display_name `Sleep` renders as `Sleep team`. `.headline`, in team color. |
| `tile.face.noInstrumentsYet` | Tile face when the team exists but has zero instruments | `No tracks yet — tap to add one.` | `.callout`, centered, `.secondaryLabel`. Replaces the primary instrument value slot. |
| `tile.face.freshness.justNow` | Freshness subtext when last event was <60s ago | `logged just now` | `.caption2`, `.secondaryLabel` |
| `tile.face.freshness.minutesAgo.format` | Freshness subtext, minutes window | `logged {n}m ago` | Same treatment. `n` is integer minutes; only render when 1 ≤ n ≤ 59. |
| `tile.face.freshness.hoursAgo.format` | Freshness subtext, hours window | `logged {n}h ago` | 1 ≤ n ≤ 23 |
| `tile.face.freshness.daysAgo.format` | Freshness subtext, days window | `logged {n}d ago` | 1 ≤ n ≤ 30 |
| `tile.face.freshness.over30days` | Freshness subtext when last event was >30 days ago | `logged a while ago` | Never "missed" / "overdue" / "you haven't logged in N days" |
| `tile.face.freshness.never` | Freshness subtext when there are instruments but no events yet | `nothing logged yet` | Neutral; never accusatory |
| `tile.detail.subtabChat` | Sub-tab bar label (Chat) | `Chat` | Standard segmented control |
| `tile.detail.subtabSheet` | Sub-tab bar label (Sheet) | `Sheet` | Standard segmented control |
| `tile.sheet.addTrackButton` | "+ Add a track" button in the Sheet tab header | `+ Add a track` | `.callout`, accent color, right-aligned in tile header strip |
| `tile.sheet.addTrackSeededMessage` | When user taps "+ Add a track", inject this as a coordinator-initiated bubble in **the tile's own Chat** (NOT coordinator chat — adding a track inside a tile stays inside that tile's conversation with the domain agent) | `I'd like another track here.` | Inline; user replies with what they want |
| `tile.sheet.allEventsDisclosure` | Collapsed disclosure label below instrument grids | `All events ({n})` | `n` is count of non-chat events for this domain in the last 30 days. `.body`, `.secondaryLabel` |
| `tile.sheet.allEventsEmpty` | Body of disclosure when expanded with no events | `No state changes yet for this team.` | `.callout`, `.secondaryLabel` |

#### 5.6.3 Domain agent — out-of-scope deflection (new clause in `RolePromptTemplates.swift`)

When a user in a team tile's chat asks the domain agent about a different domain, the domain agent MUST reply with the verbatim template (substituting the two `{…}` slots). It must NOT silently log the off-domain event.

| String key | Surface | Verbatim copy | Treatment |
|---|---|---|---|
| `domain.deflection.outOfScope.format` | Domain agent's reply when user asks an out-of-domain question | `That's a {guessed_domain} thing — I only know about {your_domain_name}. Want me to ping the {guessed_domain} team, or paste it in the Outkeep chat?` | Normal `DomainBubble`. Followed by one chip per row 5.6.3a/b. |
| `domain.deflection.chip.takeToOutkeep` | Chip below the deflection bubble (always shown) | `Take this to Outkeep` | One-tap action: copies the user's original message into coordinator chat draft, switches to landing. Coordinator chat draft is pre-filled but NOT sent — user hits send. |
| `domain.deflection.chip.pingOtherTeam.format` | Chip below the deflection bubble (only shown when `guessed_domain` exists as an active team) | `Ping the {guessed_domain} team` | One-tap action: navigates to that team's tile Chat, pre-fills the input with the user's original message, NOT sent. |

**Note for Implementer:** if `guessed_domain` is uncertain or no team matches, render only the deflection sentence + `Take this to Outkeep` chip. Never invent a `guessed_domain` to fill the slot — substitute `something else` and drop the "Ping" chip:
- Fallback verbatim: `That looks like something outside {your_domain_name}. Want me to paste it in the Outkeep chat?`

**v1.6 candidate (deferred per team-lead):** the phrase "paste it in the Outkeep chat" has slightly stiff prosody (brand-name-plus-noun). v1.5 keeps it as-is for consistency between chip label (`Take this to Outkeep`) and the deflection prose. If dogfooding shows the line reads awkwardly in real use, the swap is: `"…paste it in the main chat?"` (same place, smoother cadence, loses the brand reinforcement). Do not change in v1.5.0.

#### 5.6.4 Settings — modal (new in v1.5)

| String key | Surface | Verbatim copy | Treatment |
|---|---|---|---|
| `settings.modal.title` | Nav bar of the gear-icon modal cover | `Settings` | `.large` |
| `settings.modal.closeButton` | Top-left close affordance | `Done` | Standard SwiftUI modal-cover dismiss |
| `tile.header.perTeamGearLabel` | Accessibility label for the secondary gear inside a tile header (per-team settings) | `{team_name} team settings` | E.g., `Sleep team settings`. Not user-visible text; accessibility only. |

#### 5.6.5 Strings to FIX in `design/ui-specs.md` (carried over from v2 §9 — never actioned)

These three strings in the existing designer doc still contain the banned "decay" / "hard to keep up with" framing and must be updated as part of the Designer's v1.5 layout spec. The replacements are listed verbatim below for direct paste.

| ui-specs.md location | Current (banned) | Replace with (verbatim) |
|---|---|---|
| L203 — Chat input placeholder when empty-state greeting is showing | `Say hi, or tell me what's been hard to keep up with.` | `Type, or hold the mic to talk.` |
| L235–245 — ChatEmptyState greeting body | `I'm here to take care of the maintenance work on the systems you build for yourself, so they don't decay when life shifts.\n\nNo quiz, no setup forms.\nWhen you're ready, tell me what's been hardest to keep up with lately.` | Render the §1.1 greeting from `coordinator-empty-state-v2.md` via `CoordinatorEmptyStateCopy.greeting(forLocalHour:)`. Do NOT hard-code a duplicate copy in the view — the function already exists in `Agent/CoordinatorEmptyStateCopy.swift` and is the single source of truth. Drop the static greeting body block entirely; the view should call the function. **Rebrand note:** the function's emitted strings currently say `"I'm Steward."` / `"Morning. I'm Steward."` — Implementer must update them to `"I'm Outkeep."` / `"Morning. I'm Outkeep."` as part of the §5.6.8 rename pass. Same Agent file, same function; copy only. |
| L614 — Settings "+ Add a team via chat" row (now obsolete in v1.5 — replaced by `landing.spawnTile.coordinatorSeededMessage` above) | `Tell me about the new team — what's the part of your life that's been hardest to keep up with? Name and role are up to you; I'll propose a starting shape.` | Remove the Settings row entirely. The spawn affordance lives on the landing grid (5.6.1). If any code still references this Settings row in v1.5, use the same verbatim string from `landing.spawnTile.coordinatorSeededMessage`. |

#### 5.6.6 Strings to DELETE outright in v1.5

| Location | Why deleted |
|---|---|
| `ui-specs.md` §2.6 TodayEmptyState (L405–442) — including "Nothing here yet — and that's the right starting point." | The Today tab no longer exists. The landing surface IS the new Today; its empty state is `landing.spawnTile.label` + `landing.spawnTile.subtitle` (5.6.1). |
| `ui-specs.md` §2.7 (domains-exist-no-events-today empty state) | Same reason — Today is gone. Per-team "no logs yet today" framing now lives at the tile-face freshness level (5.6.2). |
| `RootTabView.swift` — entire file | Replaced by `RootView.swift` per §3.1 / §5.1 layout. Keep behind a build flag until v1.5 cuts a release, then delete. |
| `Views/Today/` — entire folder | Today tab is gone. Components that survive (e.g., `InstrumentCard`, `MorningBriefCard`) get moved into `Views/Tile/Sheet/` and `Views/Coordinator/` respectively. |

#### 5.6.7 Anti-pattern reminder (re-stated)

Even for new strings the Implementer might invent (e.g., toast text, accessibility labels), the v1 anti-moralization rules still apply. Banned tokens, all surfaces, all modes:

- `decay`, `decaying`, `slipping` (in user-visible copy; "slipping" IS allowed inside the **role-prompt** for the "push back" tone toggle per v2 §7.2)
- `streak`, `streak reset`, `back on track`
- `you should have`, `you didn't`, `you missed`
- `executive function`, `executive dysfunction`, `ADHD`, `protocol`, `adherence`
- `quiz`, `setup wizard`, `onboarding flow` (in copy — internal code names are fine)
- Exclamation marks. Anywhere. The voice is calm.
- Emoji in any LLM-emitted text. UI may use SF Symbols.

#### 5.6.8 Rebrand: Steward → Outkeep (mechanical code-string rename)

The product rename is user-facing only — internal codebase identifiers (Swift module name, `ios/Steward/` directory, `Steward.xcodeproj`, type names like `CoordinatorEmptyStateCopy`, file names, test names) **stay as "Steward"**. Only string literals that reach the user need updating. This sub-section gives Implementer (and rename pod #57) the canonical grep + replacement list. Tagline `splash.motto` from §5.6.1 is the only new copy; everything else is a verbatim rename of an existing user-visible string.

| Location (Swift file) | Current literal | Replace with | Notes |
|---|---|---|---|
| `Agent/CoordinatorEmptyStateCopy.swift` — `greeting(forLocalHour:)` | `"I'm Steward."` and `"<salutation>. I'm Steward."` (Morning / Afternoon / Evening variants) | `"I'm Outkeep."` and `"<salutation>. I'm Outkeep."` | The function is the single source of truth for the greeting per §5.6.5; rename here propagates everywhere. |
| `Views/Chat/ChatView.swift` — `.navigationTitle("Steward")` | `"Steward"` | `"Outkeep"` | Nav-bar title of the full coordinator chat view. Matches `landing.appBar.title` from §5.6.1. |
| `Views/Chat/MessageBubble.swift` (or wherever `CoordinatorBubble`'s label comes from — currently `"Steward"`) | `"Steward"` | `"Outkeep"` | Label rendered above coordinator bubbles. The agent persona's user-facing name. |
| `Views/Chat/ChatView.swift` — `ThinkingBubble(label: "Steward", ...)` | `"Steward"` | `"Outkeep"` | The coordinator-thinking bubble label. Note: domain-thinking bubble keeps `"\(name) team is thinking"` unchanged. |
| `Views/Chat/ChatMessage.swift` — `case .stillWorkingNote:` body `"Steward took too long..."` | `"Steward took too long. Saved your message — tap to retry."` | `"Outkeep took too long. Saved your message — tap to retry."` | System note shown on turn timeout. |
| `Views/Chat/ChatView.swift` — turn-timeout / "still working" toast | any literal containing `"Steward"` | replace with `"Outkeep"` | |
| `Notifications/NotificationTemplate.swift` — `onboardingFollowup` body | `"You set up the {name} team this morning. Anything to log? Hold the mic and just talk."` and `"How's {name} feeling? Anything to log — or nothing's fine too."` and `"Anything else to catch from today? Two seconds of voice works."` and the title `"Steward"` | titles change from `"Steward"` to `"Outkeep"`; bodies have no "Steward" mention and stay as-is | Title field on `Rendered` only. Bodies are untouched. |
| `Notifications/NotificationTemplate.swift` — `windDown` / `instrumentNudge` / `recoveryNudge` / `commitmentDue` / `morningBrief` title strings | any title literally `"Steward"` | `"Outkeep"` (where applicable) | The shipped templates use kind-specific titles ("Good morning", "Wind-down", "Coming up", etc.), so most titles don't need rename — but every place where `"Steward"` is used as the title (e.g., onboarding-followup) does. |
| `Notifications/NotificationActionRouter.swift` — `defaultSuggestedPrompt` strings | text containing `"Steward"` (none currently — verify) | n/a if absent | Verify with grep; nothing flagged in current code. |
| (potential) `Views/Today/*` — any "Steward" literal | n/a | the entire folder is deleted per §5.6.6 | No work needed; folder goes away. |
| (potential) `Views/Settings/*` — any "Steward" literal in About sheet, audit log header, etc. | hunt with grep | `"Outkeep"` (where applicable) | E.g., About section likely says "About Steward" — becomes "About Outkeep". `AboutSection.swift`. |
| `Resources/InfoPlist.strings` or `Info.plist` — `CFBundleDisplayName` | `"Steward"` | `"Outkeep"` | **Yes, change it.** The home-screen icon label is the point of the rebrand; user expects to see "Outkeep" under the icon after install. Already owned by impl-brand pod task 8a per team-lead. |
| (potential) `Resources/Localizable.strings` (if any) | n/a — v1 ships English-only with literal Swift strings | n/a | |

**Grep helper for Implementer:** `grep -rn '"Steward"' ios/Steward/` will surface every literal. Then human-review each: keep those that are internal logger tags / audit-log "actor" values / debug strings; replace those that reach `Text(...)`, notification titles/bodies, `.navigationTitle(...)`, alert messages, and accessibility labels.

**Audit-log `actor` field**: events from the coordinator currently have `actor='coordinator'` or `actor='system'` in the events table. These are **internal identifiers**, not user-visible strings, and should NOT change. The audit-log VIEW in Settings, when rendering "Steward did X" rows for the user, should map `actor='coordinator'` → display string `"Outkeep"`. Don't touch the database column values.

**Test suites**: tests that assert on `"Steward"` substrings will need updating to `"Outkeep"`. Tests that assert on `actor='coordinator'` (internal) stay as-is. Rename pod should run `swift test` after the pass to surface anything missed.

---

## 6. Out of scope for v1.5

For transparency, the following are deferred to v1.5.x or v1.6:

- **iPad / Mac layout** — v1.5 ships iPhone-only. The 2-column grid pattern extends naturally to 3- or 4-column on iPad later.
- **User-pinned primary instrument per team** — v1.5.0 uses most-recently-updated as primary. User-pinning is a v1.5.x add.
- **Drag-to-reorder tiles** — v1.5.0 ships fixed order: by creation timestamp ascending, "+ Spawn a team" always last. Reordering is a v1.5.x add.
- **Team archive without deletion** — already in v1; preserved.
- **Coordinator brief inside a team tile** — explicitly NOT shown per §3.4. Brief is coordinator-scoped only.
- **Sub-tab persistence across launches** — v1.5.0 always defaults team tile to Chat sub-tab on cold open. Last-selected persistence is a small follow-up.
- **`agent.cross_consult` tool** — deferred to v1.6 per Arch (Appendix C of impact doc). v1.5 cross-team synthesis uses N sequential `agent.handoff` calls in the coordinator turn loop. The user-facing UX is unchanged; only the back-end efficiency is left on the table.
- **Tile-Chat "via Outkeep" disclosure** — v1.6, contingent on dogfooding friction signal per §2.7 edge case note.
