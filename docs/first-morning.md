# First morning with Steward

You have the app on your phone. Onboarding ran. You're looking at the Chat tab. This is what happens next.

For build/deploy steps, see `sunday-morning-startup.md`. For the design rationale, see `../design/coordinator-empty-state-v2.md`. This file is just "what to do in the first five minutes."

---

## What you'll see first

A single greeting bubble. The exact text depends on the local hour:

> **Morning. I'm Steward. Tell me something I should catch — sleep, money, the kitchen, a thing on your mind — or say "walk me through it" and I'll help you set up a first piece.**

(Substitute "Afternoon" / "Evening" for the salutation, or no salutation at all between 00:00 and 04:00.)

Below the input, two tappable chips:

- **Catch something**
- **Walk me through it**

That's the whole opening surface. No streak counters, no goal-setting wizard, no "tell us about yourself" form. The next move is yours.

---

## Two ways in. Pick whichever feels easier right now.

The coordinator routes deterministically based on your first message. You don't need to think about which branch you're in — just type or tap.

### Branch A — capture-first (you have something concrete to log)

Tap **Catch something** (which just focuses the input and changes the placeholder), or just start typing. Say something real:

- *"slept 6 hours and weight is 178"*
- *"spent $80 on groceries"*
- *"bed-rotted today and need to do laundry"*

Send. Three things happen:

1. **It logs silently.** No "are you sure?" No reformatting. Whatever you said becomes an event.
2. **One-sentence acknowledgement.** Something like *"Got it — 6 hours sleep, 178 weight, logged."* If the LLM produces something off, the fallback is literally just `Logged.`
3. **Maybe a follow-up offer.** If what you logged has a recurring shape (sleep, weight, spending, mood, a chore), you'll get one sentence asking if you want to start tracking it. Examples:
   - Sleep: *"Want me to start keeping sleep for you, so you don't have to remember to log it? Quick yes or no."*
   - Money: *"Should I start keeping a running tally on spending? You can give me a budget or just let it accumulate."*
   - Mood: *"Want a quiet log of how the days feel? No targets, no scores — just somewhere it lives."*

   Say **yes** and it spawns a team (e.g., Health) with one matching instrument (e.g., sleep as a 7-day rolling average), defaulted to gentle behavior. You'll get *"Done. You have a Health track now, with sleep as a 7-day rolling average. I'll add to it whenever you tell me. Anything else on your mind?"*

   Say **no** and you get *"Cool. I'll keep the log either way — tell me anytime."* The event still exists. You can come back to the offer whenever.

If what you logged is a one-off ("called mom"), there's no follow-up offer. Just the acknowledgement.

### Branch B — setup-first (you'd rather be walked through it)

Tap **Walk me through it** (fills the input with `walk me through it`), then send. The coordinator runs a short scripted flow. One question per bubble. Defaults always proposed.

**Step 1.** One open question:

> *"Cool. One question to start: what's one thing you'd like me to help carry? Could be sleep, money, the kitchen, therapy follow-through, a hobby — whatever's sitting on you. We can add more later; nothing's permanent."*

Five chips below: `Sleep · Money · The kitchen · Hobbies · Something else`. Tap one to fill the input, or type your own answer.

**Step 2.** It proposes a team name and asks how it should act:

> *"Got it. I'll call this the Health team. How should it act?"*
>
> - **Stay gentle. Just track.** *(pre-selected default)*
> - **Push back a little when I'm slipping.**
> - **Push hard. Call me out when needed.**
>
> Plus a small disclosure link: *"See exact instructions (advanced)"* — reveals the raw role prompt only if you tap it.

A single tap on "Looks good" with the default selected advances. You don't have to read the alternatives.

**Step 3.** It proposes exactly one starting instrument — never more — using plain words, not "instrument" or kind names:

| If your team is… | Default first thing |
|---|---|
| Health | sleep hours, 7-day average |
| Money | weekly discretionary spending tally (optional limit) |
| Home | 3-item daily room reset (you name the three items when you do it) |
| Hobbies | weekly "what did I actually touch" log |
| Social | small weekly target (e.g., "reach out to one person") |

Three chips: `Yes · Different · Skip for now`.

- **Yes** → `Added.` Then step 4.
- **Different** → *"Cool — describe what you'd want instead in your own words. Rough is fine."* You describe; it proposes an alternate; repeat until yes.
- **Skip for now** → *"Cool, the team's there without it. We can add later."* Then step 4.

**Step 4.** *"Want to add a second one, or are we good for now?"* Chips: `Add one · Good for now`. If you add one, you loop step 3. If you're good, advance to step 5.

**Step 5.** Cadence proposal:

> *"I'll send a quiet morning brief at 7am tomorrow and a wind-down nudge tonight at 10:30. Sound right?"*

Chips: `Sounds right · Change times · Skip nudges`. Change times opens a native inline time picker. Skip nudges schedules nothing.

**Step 6.** Script exit:

> *"Done. You can tell me anything now — log an event, ask how something's going, or just talk. I'll be here."*

The scripted flow is over. From here, the coordinator runs free.

---

## After the first conversation

You're now in free chat. The coordinator does whatever your message implies. Some examples of what you can say:

### Log an event

Just say it. Quantities, units, rough estimates — all fine.

- *"three coffees today"*
- *"workout, 45 min"*
- *"spent $32 at Whole Foods"*
- *"slept 7 hours, woke up twice"*

The coordinator either logs it as a plain event or hands off to the relevant domain agent, which updates the matching instrument. Math is done in Swift, never by the LLM, so the numbers are right.

### Ask how something is going

- *"how am I doing on sleep this week?"*
- *"how much discretionary spend is left?"*
- *"what's my 30-day weight trend?"*

The domain agent reads the instrument state directly — it doesn't estimate from the event log. If the answer is "you haven't logged anything in three days," it'll say that without moralizing.

### Spawn another team

Once you've got one team running and you want another, just say so:

- *"make me a Money agent for discretionary spend, $300/wk, remind me Sunday night"*
- *"add a Home team with a 3-item morning reset"*

The coordinator short-circuits the full Branch B script when you describe what you want — it just creates the team, the instrument, and the cadence and tells you it's done.

### Add a notification

- *"nudge me at 10:30 to start winding down"*
- *"remind me to call mom this weekend"*

The first creates a scheduled notification (visible in Settings → Notifications). The second creates an iOS Reminder via EventKit — it shows up on the lock screen and in the Reminders app.

### Tell it to back off

- *"switch to mercy mode for a few days"* — soft templates, max 1 proactive notification/day on top of the morning brief, no gap reviews.
- *"pause for a week, I'm on vacation"* — silences all proactive notifications.
- *"quiet hours until 8am"* — temporarily shifts the quiet window.

### Adjust the cadence cap

- *"up the cap to 5/day this week, I'm in a focus push"*
- *"don't send anything before 9am"*

---

## What the other tabs do

### Today

Top section: morning brief (regenerated on open if the last one is older than 6 hours). Below that, active instruments grouped by team, each as a card showing current state + delta vs yesterday. Upcoming commitments (next 24h). Upcoming notifications (next 24h, dismissable).

If you haven't spawned any team yet, the empty state nudges you back to Chat.

### Settings

Quiet hours, morning brief time, notification cap, min gap. Mercy and pause toggles with optional duration. Teams list (rename, edit role prompt, archive). **Recent agent actions** — every external action with the agent's `reasoning` field and a working undo button. Voice capture toggle. Data export (JSON).

The audit log is where you go when an agent did something unexpected. Every calendar write, reminder create, notification schedule, instrument mutation is there with the agent's reason and a one-tap undo.

---

## What's deliberately not here

So you recognize the absences as design, not bugs:

- **No streak counts.** Lapse days are ordinary. The coordinator won't tell you you broke a streak because there are no streaks.
- **No "you should have."** Anti-moralization clauses are in both coordinator and domain agent system prompts. Banned patterns include "let's get back on track," "you committed to," and quantitative shame ("you missed 4 days this week").
- **No exclamation marks.** Anywhere. The voice is calm. If you see one, that's a regression — file it.
- **No emoji in coordinator messages.** SF Symbols may appear as UI affordances; the LLM doesn't emit emoji.
- **No "domain" / "instrument" / "role_prompt" in user-facing copy.** The coordinator says "team", "track", "how it should act." If it slips into the technical terms in chat, that's also a regression.
- **No goal-setting form.** Targets are optional and proposed inline; you can always say "skip."
- **No streak reset shame after a gap.** After 3+ days quiet in a domain, mercy mode auto-engages and the coordinator switches to "smallest possible re-entry action, no review of the gap unless you ask."

---

## If the first turn feels off

The most likely cause is that you're talking to the mock LLM (it stamps a `STUB` chip on every reply). Check the banner at the top of Chat — it'll tell you exactly which condition tripped (Apple Intelligence off, model still preparing, device not eligible, SDK not compiled in) and what to fix. See `sunday-morning-startup.md` §6 for each.

If you're definitely on the real model and something is off — a banned phrase appeared, the script asked two questions in one bubble, the coordinator proposed more than one instrument at step 3 — file it as a regression with the literal bubble text and which step you were on.
