# Coordinator Empty-State Script v2

**Status:** authoritative source for Track B's coordinator system-prompt augmentation when `domains.count == 0`, and for Track E's empty-state UI copy. Spec.md §16 is the structural skeleton; this file is the actual human experience.

**Scope:** only the first conversation a user has, from cold launch (no domains, no events) through to either (a) at least one captured event or (b) at least one spawned domain + instrument + scheduled nudge. Does not cover post-onboarding behavior.

---

## 0. Principles in force (non-negotiable)

These are derived from spec §2 and the lit-review. Every line below is downstream of these.

1. **Turn 1 must be useful.** The first user message produces either a logged event or a tangible scaffolding step — never just more dialogue.
2. **Dual entry.** The opening accommodates both "I need to dump something off my head" and "I want to set this up properly." No branch is the default; the user's first message picks.
3. **One question at a time.** Never stack two questions in one bubble. Sequential commitments survive cognitive load that parallel ones don't.
4. **Defaults always proposed, confirmation always one-tap.** Never ask the user to do the future-self scheduling work the app is supposed to absorb.
5. **No clinical language.** Banned tokens in user-facing copy: *decay, decaying, executive function, executive dysfunction, ADHD, protocol, empty state, script, onboarding, domain* (in the technical sense), *role_prompt, instrument* (use natural words), *adherence, compliance, intervention, baseline*.
6. **No "you" sentences that imply the user has been failing.** "What's been hardest to keep up with" is banned. "What you've been putting off" is banned. Reframe everything as forward-looking ("what you'd like backed up") or neutral-curious ("what's on your mind").
7. **No moralization, no streaks-with-resets, no "let's get back on track."** Reiterating because the empty-state moment is where the temptation peaks.
8. **Plain, low-affect copy.** Short sentences. No exclamation marks anywhere. No emoji in coordinator messages. Period.

---

## 1. The opening turn (verbatim, ships as-is)

This is what the user sees when they first land in Chat with `events.count == 0` and `domains.count == 0`. It is **rendered by the UI, not by the LLM** — Track E owns this string. The first LLM turn happens only after the user sends their first message.

### 1.1 Greeting bubble copy (verbatim)

> **Morning. I'm Outkeep.**
>
> **Tell me something I should catch — sleep, money, the kitchen, a thing on your mind — or say "walk me through it" and I'll help you set up a first piece.**

Two sentences (counting the greeting). Works for both branches. The examples are concrete enough that the user has a hook even at 7am.

**Time-of-day variant.** Swap "Morning" for "Afternoon" / "Evening" based on local hour (≥04:00 & <12:00 → Morning, ≥12:00 & <17:00 → Afternoon, else Evening). If hour is between 00:00 and 04:00, drop the greeting entirely and lead with "I'm Outkeep."

### 1.2 Suggestion chips beneath the input (verbatim)

Two tappable chips immediately under the input field. Tapping fills the input with the chip text **but does not auto-send** — user must hit send. This preserves agency and lets them edit.

| Chip label | Fills input with |
|---|---|
| **Catch something** | (empty input, cursor placed; just signals the user wants to log) — *see §1.3* |
| **Walk me through it** | `walk me through it` |

For the **Catch something** chip: instead of filling text, tapping focuses the input and changes the placeholder to **"What should I catch? (sleep, weight, a spend, a thing on your mind…)"**. This makes the affordance ambient instead of putting text the user has to delete.

### 1.3 Input placeholder when greeting is showing (verbatim)

> **"Type, or hold the mic to talk."**

(Replaces ui-specs.md line 203 string `"Say hi, or tell me what's been hard to keep up with."` — see §6.)

---

## 2. Routing logic (Track B implements)

After the user's first message, the coordinator picks a branch deterministically before calling the LLM. **Use a tiny rule-based classifier, not a model call** — the message is the first thing the user types and we cannot afford a 1–3s latency on the LLM warm-up for routing.

```
let first = userMessage.lowercased().trimmed()

if first matches SETUP_INTENT_PHRASES → BRANCH_B_SETUP_FIRST
elif first.wordCount < 3 OR first matches GREETING_ONLY → BRANCH_C_UNCLEAR
else → BRANCH_A_CAPTURE_FIRST
```

```
SETUP_INTENT_PHRASES = [
  "walk me through it", "walk me through this", "set me up",
  "help me start", "help me set up", "set up", "setup",
  "i don't know where to start", "where do i start",
  "how does this work", "what do i do"
]

GREETING_ONLY = ["hi", "hey", "hello", "yo", "sup", "morning", "ok", "okay", "k"]
```

If branch detection misfires (rare), the LLM in any branch can re-route by calling `agent.handoff` to itself with a corrected branch hint — but the v1 classifier should be tight enough that this is < 5% of real messages.

---

## 3. Branch A — capture-first

User typed something concrete. Examples: *"slept 6 hours and weight is 178"*, *"spent $80 on groceries"*, *"i bed-rotted today and need to do laundry"*.

### 3.1 Step A1 — log the event silently, then acknowledge

The coordinator calls `event.capture(text=<raw user message>)` immediately. Then responds:

**LLM prompt guidance for this step:**

> Acknowledge what was logged in one short sentence, naturally, without parroting verbatim. Don't moralize, don't compliment, don't ask follow-up questions about feelings. Examples: "Got it — 6 hours sleep, 178 weight, logged." / "Logged: groceries, $80." / "Logged — laundry on the list."

**Verbatim fallback** (if LLM fails to produce): **"Logged."**

### 3.2 Step A2 — retroactive domain offer (only when the captured event implies a recurring concern)

After the acknowledgement, in the **same turn** (one bubble per message; this is the second bubble), the coordinator offers a domain *only if* the captured event has a clear domain hint AND it's a kind of thing that benefits from tracking over time.

**LLM prompt guidance:**

> If the captured event names a quantity, a recurring behavior, or a state the user might want to see trend over time, offer to start a track for it in one sentence. Use natural verbs ("track", "keep an eye on", "remember these for you"), never "create a domain" or "spawn an instrument". Frame as a small offer with a clear escape hatch. If the event was a one-off (e.g., "called mom"), do not offer a track — just acknowledge.

**Verbatim copy templates** (the LLM should adapt slightly, but stay close to these):

| Captured event shape | Coordinator's second bubble |
|---|---|
| Sleep hours mentioned | **"Want me to start keeping sleep for you, so you don't have to remember to log it? Quick yes or no."** |
| Weight or measurement mentioned | **"I can start tracking weight over time if you want — say yes and I'll just average what you tell me."** |
| Money spent / income | **"Should I start keeping a running tally on spending? You can give me a budget or just let it accumulate."** |
| Discrete chore or to-do | **"Want me to keep this as a thing to follow up on, or are you good?"** |
| Mood / state ("bed-rotted") | **"Want a quiet log of how the days feel? No targets, no scores — just somewhere it lives."** |
| Anything else with a recurring shape | **"Should I start keeping track of this so it doesn't fall off?"** |
| One-off event with no recurrence shape | *(no follow-up; just the acknowledgement from A1)* |

**Rule:** the offer is always **one sentence**, ends with a low-stakes question, and gives the user permission to say no.

### 3.3 Step A3 — if user says yes

Coordinator spawns the relevant team and ONE matching instrument in a single confirmation. **Skip role-prompt customization in this branch** — use the default "stay gentle, just track" behavior. The capture-first user has signaled they want minimum ceremony.

**Verbatim copy after spawn:**

> **"Done. You have a Health track now, with sleep as a 7-day rolling average. I'll add to it whenever you tell me. Anything else on your mind?"**

Substitute the team/instrument names as appropriate. Always end with the open re-invitation **"Anything else on your mind?"** — never "what else should we set up?"

### 3.4 Step A4 — if user says no

Coordinator returns to neutral. **Verbatim:**

> **"Cool. I'll keep the log either way — tell me anytime."**

No further pressure. The user can come back to the offer later via natural language.

### 3.5 Step A5 — repeat-capture promotion (defers to a later session)

If the user captures 3+ similar events across sessions without spawning a track, the coordinator's morning brief (separate surface) can offer once: **"You've logged sleep three mornings in a row — want me to start a real track for it?"** This is out of scope for the empty-state script but documented here so Track B knows the hook exists.

---

## 4. Branch B — setup-first

User typed a setup-intent phrase. They want to be walked through it. The coordinator's job here is to make the walk feel small.

### 4.1 Step B1 — one open question, with examples and a fast-tap option

**LLM prompt guidance:** the LLM may rephrase slightly for warmth but must preserve structure (single question, concrete examples, permission to add more later, no "decay" language).

**Verbatim copy (default):**

> **"Cool. One question to start: what's one thing you'd like me to help carry?**
>
> **Could be sleep, money, the kitchen, therapy follow-through, a hobby — whatever's been sitting on you. We can add more later; nothing's permanent."**

**Fast-tap chips** (rendered by UI under this bubble, dismissed once user types or taps):

`Sleep · Money · The kitchen · Hobbies · Something else`

Tapping a chip fills the input with that word + the user can edit or just send.

### 4.2 Step B2 — propose team shape (one bubble, no raw prompt)

User answers with whatever they answered. Coordinator picks the matching team name (Health, Money, Home, Social, Hobbies, etc. — coordinator may invent a sensible team name if needed, e.g. "Therapy follow-through team") and offers behavioral tone toggles, **not a role_prompt**.

**Verbatim copy:**

> **"Got it. I'll call this the {Team Name} team. How should it act?"**
>
> Three tappable options below the bubble:
>
> - **Stay gentle. Just track.** *(default; pre-selected)*
> - **Push back a little when I'm slipping.**
> - **Push hard. Call me out when needed.**
>
> Plus a small text link below the three: **"See exact instructions (advanced)"** — disclosure that reveals the raw `role_prompt` only if tapped.

**Implementation note for Track B:** the three toggle options map to three preset `role_prompt` templates (provided in §7 below). The advanced disclosure shows the literal templated text and allows freeform editing for the rare user who wants it.

**Rule:** the default option is pre-selected so a single tap on the send-equivalent (a "Looks good" button) advances. The user who is overwhelmed and just wants forward motion can move without reading the alternatives.

### 4.3 Step B3 — propose ONE instrument (never more)

Coordinator proposes the single smallest instrument that maps to the team's purpose.

**LLM prompt guidance:**

> Propose exactly one instrument. Pick the easiest possible thing to log given what the user said. Describe it in plain words — never use the word "instrument" or "definition_json" or the kind name verbatim. End with a three-option chip set: yes / different / skip.

**Verbatim copy templates by team:**

| Team | Default first instrument | Coordinator's bubble |
|---|---|---|
| Health | sleep rolling-average, 7 days | **"Easiest first thing to track: sleep hours, 7-day average. I'll average whatever you tell me. Want it?"** |
| Money | weekly discretionary budget | **"Easiest first thing to track: a weekly discretionary spending tally. Give me a number if you want a limit, or skip and I'll just keep a running total. Want it?"** |
| Home | room reset checklist (3 items) | **"Easiest first thing: a 3-item daily room reset — say what the three items are when you want to do it. Want it?"** |
| Hobbies | weekly evidence log | **"Easiest first thing: a weekly 'what did I actually touch' log. No targets — just somewhere it lives. Want it?"** |
| Social | countdown commitment | **"Easiest first thing: a small weekly target — like 'reach out to one person.' Want it?"** |
| (other) | LLM proposes the smallest fitting kind from spec §6 | (LLM-generated, must follow the same structural pattern) |

**Chip options below each:** `Yes · Different · Skip for now`

### 4.4 Step B4 — handle the three responses

- **Yes:** spawn the instrument. **"Added."** Then immediately B5.
- **Different:** **"Cool — describe what you'd want instead in your own words. Rough is fine."** When the user replies, the LLM picks an alternate kind and proposes it (one bubble, same yes/different/skip).
- **Skip for now:** **"Cool, the team's there without it. We can add later."** Then immediately B5.

### 4.5 Step B5 — ask about a second instrument (one question only)

**Verbatim:**

> **"Want to add a second one, or are we good for now?"**

Chips: `Add one · Good for now`

If "Add one": loop back to B3 with the next-easiest instrument for that team. If "Good for now": advance to B6.

### 4.6 Step B6 — cadence, as a default + confirm

**Verbatim:**

> **"I'll send a quiet morning brief at 7am tomorrow and a wind-down nudge tonight at 10:30. Sound right?"**

Chips: `Sounds right · Change times · Skip nudges`

- **Sounds right:** coordinator schedules both. Advance to B7.
- **Change times:** present a small native time-picker inline (Track E spec) for each. Coordinator schedules with new values. Advance to B7.
- **Skip nudges:** schedule neither. **"Cool. You can ask me to set one up anytime."** Advance to B7.

**Note:** if current local time is already past the proposed wind-down time, drop the wind-down offer (suppressed silently). If current local time is past the proposed morning-brief time, schedule for tomorrow as normal.

### 4.7 Step B7 — close the loop, hand off to free chat

**Verbatim:**

> **"Done. You can tell me anything now — log an event, ask how something's going, or just talk. I'll be here."**

No further questions. The empty-state script is over. The coordinator drops scripted behavior and operates from its regular system prompt for all subsequent turns.

---

## 5. Branch C — monosyllabic / unclear

User typed something like "hi" or "ok" or "i don't know" or anything < 3 words that isn't a setup-intent phrase or a clear capture.

### 5.1 Step C1 — give a concrete on-ramp, no pressure

**Verbatim:**

> **"No worries. Easiest start: tell me one thing about today. How'd you sleep, or what did you have for breakfast? I'll just log it — no commitment to anything."**

After the user's next message:
- If they answer concretely → re-route to Branch A.
- If they say "walk me through it" or similar → re-route to Branch B.
- If they're still vague ("dunno", "nothing") → **"Cool, no rush. I'll be here when something comes up. You can also tap the mic and just talk if typing's annoying."** End of script. User can come back anytime.

### 5.2 Step C2 — no re-prompting

The coordinator does NOT keep nudging in-session. Branch C's exit is gentle; the day-0 followup (§6) handles re-engagement.

---

## 6. Day-0 followup (FP7) — afternoon scheduled notification

Confirmed by team-lead: ship this.

### 6.1 Scheduling rule (Track B / Track D)

At the end of the empty-state script (any branch's exit), if the user has spawned at least one domain OR captured at least one event:
- Schedule a one-shot notification for **(now + 5h 30m)**, clamped to the window [13:00, 17:00] local time. If "now + 5h 30m" falls outside that window, snap to the nearest edge.
- `kind: 'onboarding_followup'`, `scheduled_by: 'coordinator'`, counts against daily cap, **never repeats**.
- If quiet hours overlap, suppress entirely (do not reschedule).

If the user exited with neither a domain nor a captured event (true Branch C tail with nothing concrete), do NOT schedule the followup. They opted out of engagement; respect it. They'll get the next morning brief tomorrow at 7am.

### 6.2 Notification copy (verbatim, three variants)

Track B picks which variant based on what happened in onboarding:

| Onboarding outcome | Notification title | Notification body |
|---|---|---|
| User spawned a team | **"Outkeep"** | **"You set up the {Team Name} team this morning. Anything to log? Hold the mic and just talk."** |
| User captured ≥1 event but no team | **"Outkeep"** | **"Anything else to catch from today? Two seconds of voice works."** |
| User captured something AND spawned a team | **"Outkeep"** | **"How's {Team Name} feeling? Anything to log — or nothing's fine too."** |

**Tap action:** opens app to Chat tab with input focused and mic primed (no auto-message sent; user types or talks).

### 6.3 Anti-pattern reminder

**Do not** include "you committed to" / "you said you would" / "don't forget" / "your streak" in any followup copy. Ever. The notification's job is to remind the user the app exists, not to enforce.

---

## 7. Role-prompt templates for the three behavioral toggles

Track B uses these as the literal `role_prompt` written to the `domains` row when the user picks a toggle. The "See exact instructions" disclosure shows these verbatim.

### 7.1 "Stay gentle. Just track." (default)

```
You are the {display_name} agent. Your job is to keep a quiet, accurate record
of what the user tells you, and to read instrument state when asked. You do not
prompt, push, or moralize. When the user reports a lapse, you log it and offer
the smallest re-entry action only if asked. You do not mention gaps unless the
user mentions them first.
```

### 7.2 "Push back a little when I'm slipping."

```
You are the {display_name} agent. Your job is to keep an accurate record, and
to gently raise it when the user has been quiet in this domain for 3+ days or
when instrument state is drifting from a target the user set. Raise it once,
neutrally, with the smallest possible next action. Never twice in a row. Never
during quiet hours. Never with shame or comparison language.
```

### 7.3 "Push hard. Call me out when needed."

```
You are the {display_name} agent. The user has asked you to be direct.
Track accurately, and when the user is drifting from their stated goals, name
it plainly in one sentence and propose a concrete next action. You are still
forbidden from: shame language, streak counts, "you should have" framing,
moralizing about character. Direct ≠ harsh. The user can dial you back in
Settings anytime.
```

**All three templates** inherit the universal coordinator preamble (spec §7) and the anti-moralization clauses (spec §15) — those are appended automatically by Track B's prompt assembler.

---

## 8. Banned patterns (re-stated, will be enforced in review)

In all v2 empty-state copy, the following are forbidden:

- **"What's been hardest to keep up with"** / **"what you've been struggling with"** / **"what's been decaying"** — any phrasing that implies the user has been failing. Replace with forward-looking framing.
- **"Let's get back on track"** — apologetic-coach voice. Banned.
- **"You committed to" / "you said you would"** in any notification or chat copy.
- **Exclamation marks.** Anywhere. The voice is calm.
- **Emoji in coordinator messages.** UI may use SF Symbols for affordances; the LLM does not emit emoji.
- **Two questions in one bubble.** Always split into sequential turns or use one question + chips.
- **The word "domain", "instrument", "role_prompt"** in user-facing copy. Use "team", "track", "how it should act".
- **"Quiz", "form", "setup wizard"** — language that surfaces the scaffolding. The flow should feel like a short conversation, not a procedure.

---

## 9. UI-spec copy strings that need to align

The designer's `ui-specs.md` was written before this v2 script. The following lines have copy that conflicts with v2 and should be updated. (Flagging only — actual edits are for the designer to make, since their file is their source of truth for everything else UI.)

| ui-specs.md line | Current copy | Replace with |
|---|---|---|
| L203 | `"Say hi, or tell me what's been hard to keep up with."` (input placeholder, empty state) | `"Type, or hold the mic to talk."` |
| L235–245 | Greeting body including "they don't decay when life shifts" and "When you're ready, tell me what's been hardest to keep up with lately." | Replace with the §1.1 verbatim greeting from this file (two short sentences, no "decay" or "hardest to keep up with" language). |
| L242 | `"No quiz, no setup forms."` | Drop. Surfacing the scaffolding ("no quiz") still makes "quiz" present in the mind. Just don't be a quiz. |
| L420–424 | Today-empty body: "Head over to Chat and tell Outkeep what's been hardest to keep up with lately. That's where the first team gets built." | Replace with: **"Head over to Chat. Tell Outkeep something to catch, or say 'walk me through it.' That's where the first team gets built."** |
| L437 | Voice rationale: "What's been hardest to keep up with" mirrors spec §16's empty-state question — same words across surfaces. | This rationale is now obsolete. The mirror string across surfaces should be the §1.1 greeting from v2: "Tell me something to catch — or say 'walk me through it'." |
| L614 | Settings "+ Add a team via chat" injected message: "Tell me about the new team — what's the part of your life that's been hardest to keep up with? Name and role are up to you; I'll propose a starting shape." | Replace with: **"Want to add a new team — what would you like me to help carry? Name and tone are up to you; I'll propose a starting shape."** |

Designer can copy-paste these directly. No structural changes to ui-specs.md needed — only string replacements at the listed lines.

---

## 10. What's NOT addressed in v2

For transparency / handoff:

- **Permission choreography (FP1).** Architect is weighing in separately on whether EventKit permission deferral is sound given iOS revocation surfaces. v2 deliberately doesn't prescribe permission ordering.
- **Foundation Models cold-start UX (FP2).** Splash / pre-warm copy is Track E's domain. The fallback string when FM is unavailable is already correctly handled at ui-specs.md L266–275.
- **Voice capture UX inside the empty-state flow.** Assumed available; mic affordance is per ui-specs.md §1.6.
- **Subsequent days.** v2 ends when the script exits. Day 2+ behavior is spec §7 + coordinator's regular system prompt.
- **Multilingual.** All copy is English. v1 ships English-only.
