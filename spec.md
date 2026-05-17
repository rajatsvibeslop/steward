# Steward — Spec

## 0. TL;DR

Steward is a single-user, offline-first, native iOS app that acts as a **personal institutional layer**: a coordinator agent plus per-domain sub-agents that take ownership of the maintenance work for the user's foundational life systems (health, home, money, work, social, therapy follow-through, hobbies, anything else). Agents have full autonomy to read/write Calendar, Reminders, instrument-spreadsheets (built-in, with optional Google Sheets mirror), schedule local notifications, and register cron-like recurring jobs. Every external action is logged for audit. Inference runs on-device via Apple Foundation Models so the coordinator works on the subway. Spreadsheets are agent-maintained state (math is correct, formulas survive), the event log is immutable history, and a hybrid embeddings + FTS5 memory layer gives agents qualitative recall across domains. v1 ships overnight in /hackathon mode and is usable when the user wakes up Sunday morning.

## 1. Problem and goal

The user has a recurring failure pattern: builds good personal systems for tracking and life-maintenance, watches them decay after life changes or ~3 months of upkeep. The bottleneck is **maintenance overhead**: remembering to log, remembering to review, fixing drift, restarting after lapses. The literature calls this *executive continuity failure* — intentions exist, plans briefly form, then the chain from intention to execution snaps under cognitive load (`investigation/lit-review.md`).

Steward exists to absorb that maintenance overhead. The user does the living; the agents maintain the system that supports the living. The product wins if:
- Foundational systems (sleep, meals, money, mess, therapy follow-through, hobbies) stay alive across life changes
- After a lapse day, the next day feels legible and restartable without shame
- Capture friction stays low enough that logging survives even on bad days
- The user doesn't have to think about whether the *system* is still working

Anti-goals: a more aesthetic to-do list; a quantified-self dashboard the user services rather than uses; a moralizing coach; a streak-reset shame engine.

## 2. Design principles (load-bearing, not decorative)

These are extracted from the lit review and from the user's stated constraints. Every disagreement with the spec should reference one of these.

1. **Continuity over intensity.** The system survives bad days. Rolling windows beat brittle streaks. Recovery is a first-class feature, not an afterthought.
2. **Capture is radically low-friction.** Voice and chat, never form-fill. Rough estimates accepted. One-tap confirmations.
3. **Spreadsheets are state; the event log is history; memory is qualitative recall.** These are three distinct layers with no overlap.
4. **Agents propose AND act.** Full autonomy on calendar, sheets, notifications, cron. Every external action is logged with the agent's reasoning so it's auditable and reversible.
5. **Externalize state visibly.** Instruments are real spreadsheets with formulas the user can read and (if mirrored to Google Sheets) edit.
6. **Adaptive prompts, not notification spam.** Max 3 proactive notifications/day, 90-minute spacing, daily bundled brief, scale down after ignores, hard mercy mode after lapse weeks.
7. **Deterministic rules are separated from LLM dialogue.** Scoring, notification caps, mercy thresholds live in deterministic Swift code. The LLM handles dialogue, summarization, extraction, routing.
8. **Local-first, offline-first.** Everything works on the subway. Sync to Google Sheets is opportunistic, not required.
9. **Domains are runtime config, not hard-coded code paths.** Adding a new life team is a chat message: "make me a Money agent."
10. **No moralization. No shame copy. Ever.** Coordinator and domain agents have explicit anti-moralization clauses in their system prompts.

## 3. Architecture overview

```
┌──────────────────────────────────────────────────────────────┐
│                   iPhone (iOS 26+, single device)             │
│                                                                │
│  ┌─────────────────┐    ┌─────────────────────────────────┐  │
│  │   SwiftUI App   │◄──►│      Orchestrator (Swift)        │  │
│  │  - Chat tab     │    │  - Coordinator agent loop        │  │
│  │  - Today tab    │    │  - Domain agent handoff          │  │
│  │  - Instruments  │    │  - Tool router                   │  │
│  │  - Settings     │    │  - Notification scheduler        │  │
│  └─────────────────┘    │  - Sync queue worker             │  │
│                          └────────┬────────────────────────┘  │
│                                   │                            │
│         ┌─────────────────────────┼──────────────────────┐    │
│         │                         │                       │    │
│  ┌──────▼──────┐   ┌─────────────▼──────┐   ┌───────────▼──┐ │
│  │  Foundation │   │   SQLite (GRDB)     │   │   EventKit   │ │
│  │   Models    │   │  - events           │   │  - Calendar  │ │
│  │  (on-device │   │  - memory_items     │   │  - Reminders │ │
│  │   LLM +     │   │  - instruments      │   │              │ │
│  │   tools)    │   │  - commitments      │   │              │ │
│  │             │   │  - domains          │   │              │ │
│  │  NLEmbedding│   │  - notifications    │   │              │ │
│  │  (vectors)  │   │  - sync_queue       │   │              │ │
│  │             │   │  - settings         │   │              │ │
│  │  WhisperKit │   │  - FTS5 virtual     │   │              │ │
│  │  (voice)    │   └─────────────────────┘   └──────────────┘ │
│  └─────────────┘                                                │
└──────────────────────────────────────────────────────────────┘
                              │
                       (when online)
                              │
                ┌─────────────┼──────────────┐
                ▼             ▼              ▼
        ┌───────────┐  ┌─────────────┐  ┌──────────────┐
        │  Google   │  │  iCloud      │  │  Web search  │
        │  Sheets   │  │  (EventKit   │  │  (deferred,  │
        │  (mirror) │  │   transport) │  │   pluggable) │
        └───────────┘  └─────────────┘  └──────────────┘
```

Single device. Single user. Everything runs on the iPhone. The Mac is a build environment, not a runtime dependency.

## 4. Tech stack

| Layer | Choice | Why |
|---|---|---|
| UI | SwiftUI (iOS 26+) | Native, fast to build, modern |
| LLM | Apple Foundation Models framework | Free, on-device, offline, tool-use support, sufficient for routing/summarization/extraction. The user has iPhone 15 Pro+/iOS 26 |
| Storage | SQLite via GRDB.swift | Battle-tested, append-only friendly, FTS5 support, fine-grained transactions |
| Embeddings | `NLEmbedding` (NaturalLanguage framework) for v1; Core ML BGE-small for v2 | Free, on-device, no model export pain for v1 |
| Lexical search | SQLite FTS5 via GRDB | Built into SQLite; hybrid with vectors |
| Vector search | Brute-force cosine over normalized vectors in SQLite BLOB column | Dataset stays small (single user); no need for ANN libraries in v1 |
| Calendar | EventKit (iCloud Calendar + Reminders) | Native, offline-first, syncs through iCloud transparently, supports Siri/Shortcuts capture |
| Spreadsheet surface | In-app SwiftUI grid views + iCloud Drive CSV mirror (Apple `TabularData` framework for read/write) | Native, offline, no third-party auth, Numbers opens CSVs natively on iPhone/iPad/Mac |
| Local notifications | UNUserNotificationCenter | Pre-scheduled, offline reliable |
| Background tasks | BGTaskScheduler (BGAppRefreshTask, BGProcessingTask) | Opportunistic refresh only; not relied on for correctness |
| Voice capture | WhisperKit | On-device, offline, fast on Apple Silicon |
| Secrets | Keychain (KeychainAccess wrapper) | Tokens, API keys |

Package manifest (SPM):
- `GRDB.swift`
- `WhisperKit`
- `KeychainAccess`

(No Google SDKs in v1. `TabularData` and `FileManager`/`NSFileCoordinator` are Apple-native, no SPM dep needed.)

## 5. Data model

All tables in a single SQLite DB at `~/Documents/steward.sqlite`. Migrations via GRDB.

### `events` — append-only history

```sql
CREATE TABLE events (
  event_id      TEXT PRIMARY KEY,           -- ULID
  created_at    INTEGER NOT NULL,           -- unix ms
  actor         TEXT NOT NULL,              -- 'user' | 'coordinator' | 'agent:<domain>' | 'system'
  kind          TEXT NOT NULL,              -- 'log_entry' | 'instrument_update' | 'commitment_create' | 'notification_sent' | 'calendar_write' | 'sheets_write' | 'agent_action' | ...
  domain        TEXT,                       -- nullable: 'health', 'home', etc.
  instrument_id TEXT,                       -- nullable FK to instruments
  commitment_id TEXT,                       -- nullable FK to commitments
  text          TEXT,                       -- human-readable summary
  payload_json  TEXT,                       -- kind-specific structured data
  source        TEXT,                       -- 'chat' | 'voice' | 'agent' | 'cron' | 'siri' | 'sheets_edit'
  reasoning     TEXT                        -- when actor is agent, the agent's stated reason
);
CREATE INDEX events_created_at ON events(created_at);
CREATE INDEX events_domain ON events(domain, created_at);
CREATE INDEX events_instrument ON events(instrument_id, created_at);

CREATE VIRTUAL TABLE events_fts USING fts5(
  text, payload_json,
  content='events', content_rowid='rowid'
);
-- triggers to keep FTS in sync
```

**Never updated, never deleted.** All mutations to other tables emit an event.

### `memory_items` — distilled retrievable facts

```sql
CREATE TABLE memory_items (
  memory_id            TEXT PRIMARY KEY,
  type                 TEXT NOT NULL,  -- 'preference' | 'constraint' | 'lesson' | 'observation' | 'fact_about_user'
  text                 TEXT NOT NULL,
  embedding            BLOB NOT NULL,  -- normalized float32 vector
  embedding_dim        INTEGER NOT NULL,
  strength             REAL NOT NULL DEFAULT 1.0,
  last_accessed_at     INTEGER,
  created_at           INTEGER NOT NULL,
  expires_at           INTEGER,        -- nullable
  domain               TEXT,
  provenance_event_ids TEXT            -- JSON array of event_ids
);
CREATE INDEX memory_domain ON memory_items(domain, strength DESC);
CREATE INDEX memory_strength ON memory_items(strength DESC, last_accessed_at DESC);

CREATE VIRTUAL TABLE memory_fts USING fts5(
  text, content='memory_items', content_rowid='rowid'
);
```

### `instruments` — agent-maintained state machines (the "spreadsheets")

```sql
CREATE TABLE instruments (
  instrument_id    TEXT PRIMARY KEY,
  domain           TEXT NOT NULL,
  kind             TEXT NOT NULL,        -- see section 6
  name             TEXT NOT NULL,
  definition_json  TEXT NOT NULL,         -- kind-specific config
  state_json       TEXT NOT NULL,         -- current values (rolling sums, averages, counts)
  created_at       INTEGER NOT NULL,
  last_updated_at  INTEGER NOT NULL,
  review_cadence   TEXT,                  -- 'daily' | 'weekly' | 'on_event' | NULL
  archived_at      INTEGER,
  csv_mirror_path  TEXT                   -- nullable; relative path in iCloud Drive folder for the CSV mirror
);
CREATE INDEX instruments_domain ON instruments(domain) WHERE archived_at IS NULL;
```

### `commitments` — promised actions

```sql
CREATE TABLE commitments (
  commitment_id    TEXT PRIMARY KEY,
  title            TEXT NOT NULL,
  status           TEXT NOT NULL,    -- 'active' | 'done' | 'abandoned' | 'snoozed'
  due_at           INTEGER,
  decision_by      INTEGER,
  domain           TEXT,
  importance       TEXT NOT NULL,    -- 'low' | 'medium' | 'high'
  linked_instrument_id TEXT,
  created_at       INTEGER NOT NULL,
  completed_at     INTEGER,
  ek_reminder_id   TEXT              -- EventKit Reminders bridge
);
CREATE INDEX commitments_status ON commitments(status, due_at);
```

### `domains` — life teams as runtime config

```sql
CREATE TABLE domains (
  domain           TEXT PRIMARY KEY,           -- 'health', 'home', etc.
  display_name     TEXT NOT NULL,
  role_prompt      TEXT NOT NULL,              -- the system prompt for this agent
  tool_scope_json  TEXT NOT NULL,              -- which tools this agent can call
  default_quiet_hours TEXT,
  created_at       INTEGER NOT NULL,
  archived_at      INTEGER
);
```

### `notifications` — schedule + audit

```sql
CREATE TABLE notifications (
  notification_id  TEXT PRIMARY KEY,
  scheduled_for    INTEGER NOT NULL,
  delivered_at     INTEGER,
  acted_at         INTEGER,
  outcome          TEXT,             -- 'opened' | 'snoozed' | 'dismissed' | 'logged_event'
  domain           TEXT,
  instrument_id    TEXT,
  kind             TEXT NOT NULL,    -- 'wind_down' | 'morning_brief' | 'instrument_nudge' | ...
  title            TEXT NOT NULL,
  body             TEXT NOT NULL,
  action_context_json TEXT,          -- what the app should do on tap
  un_request_id    TEXT,             -- iOS UNNotificationRequest identifier
  scheduled_by     TEXT NOT NULL,    -- 'user' | 'coordinator' | 'agent:<domain>'
  cancelled_at     INTEGER
);
CREATE INDEX notifications_scheduled ON notifications(scheduled_for) WHERE delivered_at IS NULL AND cancelled_at IS NULL;
```

### `sync_queue` — outbound external writes (CSV mirror for v1; pluggable for future targets)

```sql
CREATE TABLE sync_queue (
  queue_id         TEXT PRIMARY KEY,
  target           TEXT NOT NULL,        -- 'csv_mirror' (v1); 'sheets' (v1.1 if added)
  operation        TEXT NOT NULL,        -- 'write_instrument_csv' | 'write_event_log_csv' | 'reconcile_user_edits'
  payload_json     TEXT NOT NULL,
  enqueued_at      INTEGER NOT NULL,
  attempted_at     INTEGER,
  completed_at     INTEGER,
  attempt_count    INTEGER NOT NULL DEFAULT 0,
  last_error       TEXT
);
CREATE INDEX sync_pending ON sync_queue(target, enqueued_at) WHERE completed_at IS NULL;
```

### `settings` — single-row JSON blob

```sql
CREATE TABLE settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  settings_json TEXT NOT NULL
);
```

Settings shape (initial):
```json
{
  "quiet_hours": {"start": "22:00", "end": "05:00"},
  "morning_brief_time": "07:00",
  "max_proactive_notifications_per_day": 3,
  "min_notification_gap_minutes": 90,
  "mercy_mode_until": null,
  "pause_until": null,
  "csv_mirror_enabled": true,
  "icloud_drive_folder": "Steward",
  "voice_capture_enabled": true,
  "default_agent_temperature": 0.7
}
```

## 6. Instrument type system

Instruments are typed state machines. The user (via the coordinator) creates instances; events mutate them; the state is the canonical "where do I stand" answer.

### Built-in kinds for v1

| Kind | Definition | State | Use |
|---|---|---|---|
| `running_accumulator` | `{unit, daily_target?, weekly_target?, capture_prompt}` | `{today_total, seven_day_avg, thirty_day_avg, last_event_at}` | Productive non-work hours, movement minutes, water intake |
| `bounded_budget` | `{unit, period: 'daily'\|'weekly'\|'monthly', limit, rollover: bool}` | `{period_total, remaining, period_start_at, recent_entries: [...]}` | Discretionary spend, screen-time minutes, takeout meals |
| `rolling_average` | `{unit, window_days, smoothing: 'mean'\|'ema'}` | `{current, window_values: [...], last_event_at}` | Weight trend, sleep hours, mood |
| `countdown_commitment` | `{target_count, window: 'day'\|'week'\|'month', success_event_kind}` | `{count, target, window_start, window_end, completed_events: [...]}` | "Three workplace push-backs this week" |
| `weekly_evidence_log` | `{prompt, week_start_dow: 1}` | `{current_week_entries: [...], previous_weeks_summaries: [...]}` | Therapy homework, "small wins" log |
| `checklist` | `{items: [{id, label, recurrence?}]}` | `{checked_today: [...], streak_by_item: {...}}` | Morning routine, room reset |
| `bounded_window` | `{kind: 'time_window', start_target, end_target, compliance_metric}` | `{nights_in_window: [...], current_compliance_pct}` | Sleep window adherence |

### Instrument lifecycle

```
[user message: "track my discretionary spend, $300/wk"]
        │
        ▼
[coordinator → Money agent (spawned if not exists) → instrument.create]
        │
        ▼
[instruments row written]
[event emitted: kind='instrument_create', actor='agent:money']
[sheets sync queued: create new tab "Discretionary Spend"]
        │
        ▼
[user message later: "spent $40 on dinner"]
        │
        ▼
[Money agent → instrument.apply_event(spend, 40, "dinner")]
        │
        ▼
[event emitted, instrument state recomputed (remaining = $260), sheets sync queued]
```

### Formula evaluation

Instrument state is recomputed deterministically in Swift, not by the LLM. The kind-specific updater function takes `(currentState, event) -> newState`. This is the central enforcement of "math is correct" — the LLM never does arithmetic on instrument state.

### Custom kinds (v2)

In v2, the coordinator can define a new kind by writing a small expression for the update function (sandboxed eval). For v1, the seven built-in kinds cover the realistic surface.

## 7. Agent architecture

### Two-tier model

**Coordinator agent** — the only thing the user chats with by default. Responsibilities:
- Triage incoming messages: respond directly, log, route to domain agent, or do a cross-domain action
- Generate the morning brief
- Weekly review (cross-domain pattern recognition)
- Spawn new domains on user request
- Reconcile conflicts between domain agents

**Domain agents** — one per life team. Each has:
- A `role_prompt` row in `domains` table (editable from chat: "Health agent, never moralize about missed workouts")
- A scoped `tool_scope_json` (e.g., Money agent can read Calendar but only write `commitments` with `domain='money'`)
- Domain-specific memory retrieval bias
- Authority over its own instruments

Both tiers are the same Foundation Models call; the difference is the assembled system prompt and the tool subset exposed.

### Multi-agent turn loop

```swift
func runTurn(userMessage: String) async -> CoordinatorResponse {
    var ctx = buildContext(domain: nil, userMessage: userMessage)
    var hops = 0
    var transcript: [Message] = [userMessage]

    while hops < MAX_HOPS {  // MAX_HOPS = 6
        let response = await foundationModels.call(
            systemPrompt: coordinator.systemPrompt(ctx),
            tools: coordinator.tools,
            transcript: transcript
        )

        if let toolCall = response.toolCall {
            if toolCall.name == "agent.handoff" {
                ctx = buildContext(domain: toolCall.args.domain, userMessage: toolCall.args.message)
                let domainResp = await runDomainAgent(ctx)
                transcript.append(.assistant(toolCall))
                transcript.append(.toolResult(domainResp))
                hops += 1
                continue
            }
            let result = await execute(toolCall)  // logs event, mutates state
            transcript.append(.assistant(toolCall))
            transcript.append(.toolResult(result))
            hops += 1
            continue
        }

        return CoordinatorResponse(text: response.text, transcript: transcript)
    }

    return CoordinatorResponse(text: "I went around in circles. Saved what I had.", transcript: transcript)
}
```

Hop cap prevents infinite loops. The `MAX_HOPS` is intentionally generous (6) because cross-domain reasoning is the value-add.

### Context assembly

For each agent call, the context includes:
- Current time, current location (if granted)
- Settings flags (mercy mode? quiet hours? paused?)
- Last 24h of events (filtered by domain if domain agent)
- Top-K memory items retrieved by hybrid retrieval against the user message + recent transcript
- Instrument state summary for the relevant domain(s)
- Open commitments
- Today's calendar (next 12h window)

Context budget: target <= 8000 tokens for sub-agent calls, <= 12000 for coordinator. Apple's on-device model handles this.

### Coordinator system prompt skeleton

```
You are Steward, a calm, low-bullshit personal stewardship coordinator for {user_name}.
You do NOT moralize. You do NOT shame. You treat lapses as ordinary.

Your job is to absorb the maintenance overhead of {user_name}'s life systems so they
don't decay. You can: log events, update instruments, spawn or hand off to domain agents,
schedule notifications, read/write calendar and reminders, save memories.

Domains currently active: {active_domains}.
Mercy mode: {mercy_mode_status}. If on, soften nudges, offer smallest re-entry actions only.

When the user reports an event, log it. When they ask "how am I doing", read the relevant
instrument state directly — do not estimate from the log. When a request belongs to a
specific domain, hand off to that agent via agent.handoff. When no matching domain exists
and the request implies a recurring concern, ask if they want a new domain spawned.

Never invent quantities. Never guess at instrument values. Always cite the instrument row.
After a 3+ day lapse in any domain, switch to recovery script: smallest possible re-entry
action, no review of the gap unless the user asks.
```

### Domain agent system prompt skeleton

```
You are the {Domain.display_name} agent within Steward, scoped to {domain}.
{Domain.role_prompt}

You own these instruments: {instrument_list}.
You can call these tools: {tool_scope}.
You cannot moralize, shame, or guilt the user. Lapses are ordinary. After a lapse,
offer the smallest re-entry action and do not relitigate the gap.

When the user logs an event in your domain, update the relevant instrument. When the
user asks about state, read the instrument; do not estimate. When you schedule a
notification, cap at the global policy and respect quiet hours.
```

## 8. Tool surface

Tools are Swift `Tool`-conforming structs with `generableContent` for arg parsing (Apple Foundation Models 26 pattern). Each tool emits one or more events on execution.

### Capture and logging

- `event.capture(text, domain?, kind?, payload?)` — log a freeform event; coordinator parses to determine if it should also update an instrument
- `event.list(domain?, since?, limit=20)` — recent events
- `event.recent_summary(domain?, hours=24)` — natural-language summary of recent events

### Instruments

- `instrument.create(kind, name, domain, definition)` — spawn new
- `instrument.list(domain?, include_archived=false)` — enumerate
- `instrument.read(instrument_id)` — current state
- `instrument.apply_event(instrument_id, event_kind, value, unit?, notes?)` — mutate via event (preferred over direct state writes)
- `instrument.update_definition(instrument_id, definition_patch)` — change targets, units, cadence
- `instrument.archive(instrument_id, reason)`

### Commitments

- `commitment.create(title, domain, due_at?, importance, linked_instrument_id?)`
- `commitment.list(status?, domain?)`
- `commitment.complete(commitment_id, notes?)`
- `commitment.abandon(commitment_id, reason)`
- `commitment.snooze(commitment_id, until)`

### Memory

- `memory.save(text, type, domain?, strength=1.0, expires_at?)`
- `memory.search(query, domain?, types?, limit=8)` — hybrid retrieval
- `memory.forget(memory_id, reason)` — soft delete with event log entry
- `memory.strengthen(memory_id)` — bump strength
- `memory.list_recent(limit=20)`

### Notifications

- `notification.schedule(title, body, fire_at, domain?, kind, action_context?)`
- `notification.schedule_recurring(title, body, recurrence_rule, domain?, kind, action_context?)` — RFC 5545 RRULE subset (`FREQ=DAILY`, `BYHOUR`, `BYMINUTE`, `BYDAY`)
- `notification.cancel(notification_id_or_kind)`
- `notification.list_upcoming(domain?, limit=20)`

### Calendar + Reminders (EventKit)

- `calendar.read(start, end, calendar_name?)` — events in window
- `calendar.write(title, start, end, notes?, calendar_name?)` — create event
- `calendar.modify(ek_event_id, patch)` — edit
- `calendar.delete(ek_event_id, reason)` — delete (full autonomy; logged with reason)
- `reminder.create(title, due_at?, list_name?, notes?)`
- `reminder.complete(ek_reminder_id)`
- `reminder.list(list_name?, completed=false)`

### CSV mirror (iCloud Drive, queued)

- `csv_mirror.ensure_instrument_file(instrument_id)` — idempotent; enqueues create if missing
- `csv_mirror.sync_now()` — drain queue (writes CSVs to iCloud Drive folder using `NSFileCoordinator`)
- `csv_mirror.read_overrides(instrument_id)` — pull user edits from CSV back into instrument state (reconciliation via NSFileCoordinator file-presence; rare path)

### Domain management

- `domain.create(domain, display_name, role_prompt, tool_scope?)` — spawn new life team
- `domain.list()` — what teams exist
- `domain.update_prompt(domain, new_role_prompt)` — coordinator updates a domain agent's role
- `domain.archive(domain, reason)`

### Cross-agent

- `agent.handoff(domain, message)` — coordinator delegates to a domain agent
- `agent.cross_consult(domain, question)` — coordinator asks a domain agent a question without full handoff

### Web (deferred, stubbed)

- `web.search(query, k=5)` — returns "offline" error in v1 unless online; pluggable provider for v2

### Settings + safety

- `mercy_mode.engage(until_when, reason)` — soften nudges
- `pause.engage(until_when, reason)` — silence non-critical notifications
- `quiet_hours.set(start, end)`

## 9. Memory architecture

### The split

| Layer | Mutable? | Retrieval | Purpose |
|---|---|---|---|
| Events | append-only | by time/domain/instrument_id | history, provenance, replay |
| Instruments | yes (via events) | direct read | "where do I stand" — state |
| Memory items | yes (admission + decay) | hybrid (vectors + FTS5) | qualitative recall across time |

### Admission control

Not every event becomes a memory. After each user-facing turn, the coordinator may call `memory.save` if a fact emerged that is durable and retrievable-by-similarity. Heuristics in the coordinator prompt:
- Save preferences ("I hate morning prompts before 9am") — type=`preference`, high strength
- Save constraints ("I'm allergic to peanuts") — type=`constraint`, high strength, no expiry
- Save lessons ("I bed-rot after late work nights") — type=`lesson`, medium strength, slow decay
- Save observations the user wants tracked qualitatively — type=`observation`
- Do NOT save: ephemeral states ("I'm hungry"), routine logs (use events for that), narrative chit-chat

### Hybrid retrieval

```swift
func retrieveMemoryContext(query: String, domain: String?, limit: Int = 8) async -> [MemoryHit] {
    let qVec = embed(query).normalized()

    let lexicalHits = ftsSearch(query: query, domain: domain, topK: 40)
    let semanticHits = vectorBruteForce(qVec: qVec, domain: domain, topK: 40)

    let candidates = unionByID(lexicalHits, semanticHits)
    let items = loadMemoryItems(ids: candidates.ids)

    return items.map { item in
        let cosine = dot(qVec, item.embedding)
        let bm25 = lexicalHits[item.id]?.bm25Normalized ?? 0
        let recency = recencyScore(item.lastAccessedAt ?? item.createdAt)
        let typeBonus = typeWeight(item.type)  // constraint > preference > lesson > observation
        let strengthFactor = item.strength
        let score = (0.45 * cosine + 0.25 * bm25 + 0.20 * recency + 0.10 * typeBonus) * strengthFactor
        return MemoryHit(item: item, score: score)
    }
    .sorted { $0.score > $1.score }
    .prefix(limit)
    .map { $0 }
}
```

### Decay policy

Each `memory_items` row has a `strength` (0.0–1.0). On creation, `strength = 1.0`. Decay rules:
- Time-based: strength multiplied by 0.995 each day (gentle exponential decay)
- Type modifier: constraints decay at 0.9995/day; preferences at 0.998; observations at 0.99
- Boost on retrieval (used in an agent's context window): +0.05 (capped at 1.0)
- Boost on confirmation (user re-asserts the fact): +0.20
- Soft delete at strength < 0.05 (move to archive but don't lose)

A nightly background task (or app-open task if background didn't fire) recomputes decay.

## 10. Notifications and "cron"

### iOS reality

iOS BGTasks are heuristic, not real cron. The right pattern is:
1. **Pre-schedule everything we know.** Local notifications via UNUserNotificationCenter fire offline reliably.
2. **Recurring is just N pre-scheduled.** A daily morning brief at 7am is one `UNNotificationRequest` with `UNCalendarNotificationTrigger(repeats: true)`. Recurring rules from `notification.schedule_recurring` are translated to UN calendar triggers when possible, and fall back to scheduling the next N occurrences otherwise.
3. **Opportunistic refresh via BGAppRefreshTask.** When iOS gives us a slot, we: drain sync queue, recompute upcoming notifications based on recent events (e.g., cancel wind-down nudge if user already logged sleep), refresh memory decay.
4. **Tap-to-act.** Every notification carries `action_context_json`. Tapping opens the app to a context where the relevant agent runs a one-turn loop tailored to that notification ("you scheduled this wind-down nudge; the user opened it 14 min later").

### Cap policy (enforced deterministically, not by LLM)

- Max 3 proactive notifications/day (morning brief counts as 1)
- Min 90 minutes between any two notifications
- In quiet hours: only `morning_brief` (suppressed-and-rescheduled to the wake hour if quiet hours overlap)
- In mercy mode: only morning brief + at most 1 other notification/day, and notification body uses "soft" templates
- In pause mode: nothing except calendar-driven hard reminders the user explicitly committed to

The notification scheduler runs cap checks in Swift before any `UNNotificationRequest` is registered. If a tool call from an agent would exceed the cap, the scheduler returns a `cap_exceeded` result; the agent decides what to do (often: defer to tomorrow, or replace a lower-priority pending one).

## 11. Calendar and Reminders (EventKit)

EventKit is the primary calendar transport. Why:
- Offline-first (writes locally, syncs through iCloud when available)
- Native Siri/Shortcuts integration ("Hey Siri, log to Steward: I'm walking the dog")
- Reminders are the right substrate for commitments — they show up on the lock screen, in the Reminders app, in Mac Reminders, all without us building a UI

Implementation:
- One Calendar named "Steward" (created on first run) for agent-written events
- Coordinator can write to user's default calendar too if explicitly asked
- Reminders go into a "Steward" list by default
- `calendar.delete` is fully autonomous per the user's choice — every deletion logs an event with `reasoning`

Google Calendar: NOT in v1. iCloud Calendar is what shows up on the iPhone natively; mirroring to Google Calendar adds OAuth + sync complexity for marginal benefit (user can subscribe to Google Calendar in iOS Calendar instead, which gives them GCal events readable in Steward via EventKit).

## 12. Spreadsheet surfaces (in-app grid + iCloud Drive CSV mirror)

The user's "spreadsheet" mental model is satisfied by **two surfaces**, neither of which requires Google:

### Surface 1: in-app SwiftUI grid views (primary UX)

Every instrument has a "Spreadsheet" view (tap an instrument card → opens a grid). The grid shows:
- Header row from the instrument's `definition_json` schema
- Data rows assembled from the instrument's `state_json` and the relevant subset of `events`
- A "computed values" section at the bottom showing the instrument's reactive aggregates (rolling avg, % to goal, period total, etc.) — these are recomputed in Swift on every event, never by the LLM
- Inline tap-to-edit on any data cell (writes a `manual_correction` event, which the instrument's updater function ingests like any other event)

This is what the user sees 95% of the time. It's a real spreadsheet feel without being a real spreadsheet file.

### Surface 2: iCloud Drive CSV mirror (the "open it in Numbers" surface)

Built-in instruments are the source of truth. CSVs in iCloud Drive are a one-way-ish mirror:
- On every instrument update, enqueue a `csv_mirror` sync row
- Sync worker drains the queue immediately (file writes are fast; no network dependency since iCloud Drive sync happens transparently in the OS)
- File layout in iCloud Drive `Steward/` folder:
  - `instruments/<domain>/<instrument_name>.csv` — one file per instrument with raw data rows
  - `instruments/<domain>/<instrument_name>__state.csv` — computed aggregates snapshot
  - `events/events_YYYY-MM.csv` — monthly partitioned event log
  - `README.md` — explains what these files are and warns that overwrites should be careful
- Numbers, Excel, and Google Sheets can all open these. Mac, iPad, iPhone all read iCloud Drive natively.

### User edits in Numbers

If the user opens a CSV in Numbers and edits a value, we want to pick it up. Implementation:
- `NSFileCoordinator` watches the CSV files for changes
- On change: `csv_mirror.read_overrides(instrument_id)` parses the file, diffs against current state, emits `manual_correction` events for each changed row
- The instrument's updater function processes these like any other event → state updates → in-app grid reflects the change
- Conflict resolution: last-writer-wins on a per-cell basis, with an event-log audit trail. If the user makes a destructive edit, the event log lets us see what happened.

### Why this is enough for interpretation A

The user explicitly chose Interpretation A from the formulas discussion: "agent-maintained auto-computation that updates as data flows in." This is exactly what instruments do. The CSV mirror exists for visibility ("I can open it on my Mac and see the data") and casual editing. If interpretation B (user-writable freeform formulas) ever matters, Google Sheets ships in v1.1 as an additional mirror target — the `sync_queue.target` field is already pluggable for it.

## 13. Offline and sync model

| Operation | Online required? | Offline behavior |
|---|---|---|
| Chat with coordinator | No (Foundation Models is on-device) | Works fully |
| Log event / update instrument | No | Works fully (local SQLite) |
| Read instrument state | No | Works fully |
| Memory retrieval | No (NLEmbedding is on-device) | Works fully |
| Schedule local notification | No | Works fully |
| Calendar read/write (EventKit) | Partial | Writes locally, iCloud syncs when online; reads work offline from local cache |
| CSV mirror to iCloud Drive | No | File writes are local; iCloud Drive sync happens transparently when network returns |
| Web search | Yes | Returns offline-error; agent falls back to "I don't know without lookup" |

Network state observer (`NWPathMonitor`) drives sync queue worker. UI shows a small offline badge when relevant, never blocks user action.

## 14. Voice capture

WhisperKit on-device, offline. UX:
- Hold-to-talk button in the chat input
- Releases transcript into input field; user reviews and sends
- Optional: auto-send after silence threshold (configurable, default off — friction here is worth it to avoid sending nonsense)
- Siri Shortcut: "Hey Siri, log to Steward" → opens Shortcut that captures voice → posts to a Steward URL scheme → Steward processes as if user typed it

Voice capture is **v1 not v2** because it's the single highest-leverage friction reduction per the lit review ("capture is radically low-friction"), and WhisperKit-large-v3-turbo is a 1.5GB on-device model that's plug-and-play.

## 15. Safety, mercy, and audit

### Mercy mode

A first-class toggle, not a euphemism. When on:
- Notification cap drops from 3 to 1 (morning brief only counts toward cap when in mercy)
- Notification body templates switch to softer copy ("if it feels okay" / "small win idea" instead of "you committed to X")
- Domain agents are instructed in their per-turn context: "mercy_mode=on. Offer smallest re-entry actions only. Do not review gaps."
- Auto-engages on: 3+ days of zero activity in a domain, or user-stated overwhelm in chat (coordinator detects and asks "want me to switch to mercy for a few days?")
- Exits: user-initiated, or after the `mercy_mode_until` timestamp

### Pause

Stronger than mercy. All proactive notifications suspended. Calendar events still fire (because they're commitments the user made to themselves, not agent-driven). Pause for: vacations, illness, crisis weeks.

### Audit

Every external mutation (calendar write, calendar delete, sheets write, notification scheduled, reminder created) is an event with `actor='agent:<domain>'` or `actor='coordinator'` and a `reasoning` field. Settings tab has a "Recent agent actions" view showing the last 50, each with an "undo" button that emits the inverse event and the agent that did it gets the undo in its context so it learns. (Undo for v1: deletion of calendar event = restore from event payload; deletion of reminder = recreate; notification cancel = trivial; sheets row removal = enqueue a delete sync.)

### Anti-moralization clauses

Hard-coded in both coordinator and domain agent system prompts. Specific banned patterns:
- No "you should have…" / "you didn't…"
- No "let's get back on track" framing
- No streak language
- No comparisons to past performance unless user asks
- No quantitative shame ("you missed 4 days this week")

## 16. First-run experience (no pre-seeded domains)

Steward ships with **zero pre-seeded domains** by design. The user explicitly wants to architect their first domain through chat with the coordinator, not have one guessed. This means the empty-state coordinator script is the most important UX moment in v1 — it's what determines whether the user gets a working Health agent in five minutes or bounces.

### Coordinator's empty-state protocol

When the coordinator detects `domains.count == 0`, it follows a soft scripted flow (not rigid — the user can derail it anytime):

1. **Brief self-introduction** (one paragraph; never moralize, never preach about "executive function"). Make clear the user is in charge of what gets built.
2. **One open question:** "What's the part of your life that's been decaying or hard to keep up with lately — the thing where you'd most want backup?"
3. **Listen.** Whatever the user names becomes the first domain. Coordinator does NOT propose Health first or steer.
4. **Confirm domain shape:** propose `display_name`, `role_prompt`, default tool scope. Show the proposed `role_prompt` in the chat so the user can edit it inline ("change 'never moralize' to 'sometimes push me a little'").
5. **Spawn the domain** via `domain.create`.
6. **Suggest 1–3 instruments** for that domain based on what the user described. Don't overload — offer the smallest set that captures the user's intent. Show each instrument's `kind` + `definition` and ask "want this, or do you want to design it differently?"
7. **Spawn approved instruments** via `instrument.create`.
8. **Ask about cadence:** "When during the day do you want me to check in or remind you about this? And do you want a morning brief?" Schedule notifications via `notification.schedule_recurring`.
9. **Done.** User can now log events or chat freely. Coordinator drops the script.

This flow is encoded as guidance in the coordinator's system prompt, NOT as hardcoded UI steps. The user can short-circuit ("just spawn a Money agent with a $300/wk discretionary budget and remind me every Sunday night to review") and the coordinator does it without running the full protocol.

### Why no Health pre-seed

The user's words: "i want to architect that myself with the agent instead of having you guess what i want and getting it wrong." Respect this. The cost is the first 5 minutes Sunday morning are spent spawning a domain instead of immediately logging an event. The benefit is the user owns the design from turn one, which directly serves the continuity-not-prescription principle.

### Sunday morning user journey (revised)

```
07:00  Morning brief notification fires (default time, configurable in onboarding)
07:01  User taps → app opens to Today tab → empty state explains "no domains yet, tap chat to spawn one"
07:02  User opens Chat → coordinator runs empty-state protocol
07:05  First domain (likely Health, but user's call) spawned with 2–3 instruments
07:06  User logs first real event ("slept 6 hours, weight 178, two coffees so far")
07:07  Domain agent updates instruments, confirms in chat
07:08  User schedules a wind-down nudge for tonight
07:10  User closes app
22:30  Wind-down notification fires
```

This is the realistic v1 morning. The success metric: did the spawn-first-domain conversation feel smooth, or did it feel like a quiz?

## 17. Onboarding (first launch Sunday morning)

1. Foundation Models availability check (fail soft if unavailable: explain need iOS 26+ on supported hardware with Apple Intelligence enabled)
2. Request notifications permission
3. Request EventKit permission (Calendar + Reminders)
4. Ask user for: morning brief time (default 07:00 local), default quiet hours (default 22:00–05:00 — intentionally ends before morning brief time so the brief is never silenced by quiet hours). These map to settings. Both editable later.
5. Coordinator drops user into Chat tab with the empty-state protocol from section 16. No pre-seeded anything.
6. iCloud Drive folder check — confirm iCloud Drive is enabled (Settings → [name] → iCloud → iCloud Drive). If yes, Steward creates a `Steward/` folder there for CSV mirrors. If no, app still works fully; CSV mirror just becomes local-only files in app sandbox.

## 18. UI surface (SwiftUI, three tabs)

### Chat tab
- Conversation with coordinator
- Voice button (hold to talk)
- Inline rendering of tool calls (collapsible "Steward did X" cards) so the user sees what agents are doing
- "Hand-off in progress" indicator when a domain agent is responding

### Today tab
- Morning brief (regenerated on open if last brief > 6h old)
- Active instruments grouped by domain, each as a card showing current state + delta vs yesterday
- Upcoming commitments (next 24h)
- Upcoming notifications (next 24h, dismissable)
- **Empty state** (no domains yet): friendly nudge "no life teams yet — head to Chat and tell Steward what's been hardest to keep up with"

### Settings tab
- Quiet hours, morning brief time, notification cap
- Mercy / pause toggles with optional duration
- Domains list (rename, edit role prompt, archive)
- Recent agent actions (audit log with undo)
- Data: export event log as JSON, import (deferred)
- Google sign-in
- Voice capture toggle
- About: Foundation Models version, app version

## 19. Overnight build plan

### Pre-flight (user, before sleep)
- Apple Developer account active, provisioning profile for "Steward" set up in Xcode
- iPhone connected to Mac for device deploy
- Google Cloud project created, iOS OAuth client configured (or skip; Sheets is optional)
- `steward.app` (or whatever) domain purchased (only needed if doing PWA fallback; not needed for native)

### /hackathon parallelization

The build splits cleanly into ~6 parallel tracks. Subagents can each own one and we integrate at the end.

| Track | Hours | Owner | Deliverable |
|---|---|---|---|
| A. Project scaffold + DB layer | 1.5 | subagent 1 | Xcode project, GRDB schema + migrations, all tables + FTS5, NO seed data |
| B. Foundation Models integration + agent loop | 2.5 | subagent 2 | Tool protocol conformances, coordinator + domain agent runners, multi-hop turn loop with cap |
| C. Tool implementations (event/instrument/commitment/memory) | 2.5 | subagent 3 | All non-OS tools, instrument updaters (one func per kind), memory admission + hybrid retrieval |
| D. EventKit + notifications + cron-via-notif | 2 | subagent 4 | Calendar/Reminders tools, notification scheduler with cap enforcement, recurring rule translation, BGAppRefreshTask handler |
| E. UI (Chat, Today, Settings) | 3 | subagent 5 | SwiftUI views, chat input with voice button, instrument cards, settings forms |
| F. CSV mirror + WhisperKit | 1.5 | subagent 6 | iCloud Drive folder setup, CSV writer using TabularData, NSFileCoordinator watcher for user edits, WhisperKit voice capture pipeline |

Critical path: A → B → (C, D in parallel) → E integration. Track F is parallel-deferrable.

Total estimated hours: ~13 person-hours, parallelized to ~5-7 wall hours (down from 14 after dropping Google Sheets).

### Hour-by-hour (single-thread fallback)

```
21:00–22:30  Track A: scaffold + DB
22:30–01:00  Track B: agent loop + Foundation Models
01:00–03:30  Track C: tools + instrument updaters (start D in parallel here if doing parallel)
03:30–05:30  Track D: EventKit + notifications
05:30–06:30  Track E start: minimum viable Chat + Today views
06:30–07:00  Smoke test: log event, see instrument update, get morning brief notification
07:00         Wake up, use it
```

If we run /hackathon mode with subagents, target wake-up is closer to 4–5 AM with polish time.

## 20. Sunday morning Definition of Done

When the user opens Steward Sunday morning, the following MUST work:

1. **App launches on iPhone**, Foundation Models confirmed available, Apple Intelligence active
2. **Chat tab opens**, coordinator greets and runs the empty-state protocol (section 16)
3. **Spawn first domain via chat** — coordinator proposes shape, user accepts/edits, `domain.create` writes row, the new domain agent responds in the same conversation
4. **Spawn first instruments** during the same conversation via `instrument.create`; visible in Today tab immediately
5. **Log an event** via chat ("slept 6 hours" or whatever fits the spawned domain) → coordinator hands off to the domain agent → relevant instrument updates → event appears in Today tab
6. **Read instrument state** via chat ("how am I doing on X this week?") → domain agent reads instrument, reports accurately (no LLM math; values come from the deterministic state)
7. **Schedule a wind-down or check-in notification** via chat ("nudge me at 10:30 to start winding down") → notification visible in Settings, fires at the scheduled time
8. **Morning brief notification** fires at the configured time (default 7am if user kept default during onboarding); opens to a generated brief on tap
9. **Spawn a second domain** via chat ("make me a Money agent for discretionary spend") → domain row written, agent responds in next turn
10. **Calendar read** via chat ("what's on my calendar today") → EventKit read returns today's events
11. **Reminder create** via chat ("remind me to call mom this weekend") → EventKit Reminder created, visible in iOS Reminders app
12. **Works offline** — airplane mode, all of 1–11 still work except Sheets sync (which queues for when network returns)
13. **Audit log** in Settings shows recent agent actions with `reasoning` fields, each with a working undo button
14. **Notification cap is configurable** — Settings exposes proactive-per-day cap, min gap, quiet hours; chat tool also lets user adjust ("up the cap to 5/day this week, I'm in a focus push")

If any of these fail, that's a P0 for first-day patches. Everything else is iteration.

## 21. Explicitly deferred (with reasons, not dismissals)

These are real and we should build them. They're deferred to v1.1+ because they're not on the critical path for Sunday morning, NOT because they're "out of scope."

| Item | Why deferred | Target |
|---|---|---|
| Google Calendar mirror (in addition to iCloud) | EventKit gives us iOS-native calendar; user can subscribe to GCal in iOS settings to see it via EventKit. Saves overnight OAuth pain | v1.1 if user wants cross-platform calendar visibility |
| Google Sheets mirror (in addition to in-app + CSV) | User chose interpretation A only (agent-maintained auto-computation). Sheets matters only for interpretation B (user-writable freeform formulas). Pluggable: `sync_queue.target` already supports adding 'sheets' as a target | v1.1 if user finds themselves wanting freeform formula scratch space |
| Web search adapter | Not on critical path; needs provider choice (SerpAPI vs Brave) and budget allocation | v1.1 when first useful query surfaces |
| Custom instrument kinds (user-defined update functions) | Sandboxed eval is non-trivial; seven built-in kinds cover realistic v1 needs | v1.2 |
| Multi-device sync via CloudKit | Single-device works fine for now; CloudKit adds real complexity | v2 |
| Weekly review report (cross-domain pattern recognition) | Coordinator can do ad-hoc; structured weekly report needs design + dogfooding | v1.1, ~2 weeks in |
| Microrandomized trial machinery (A/B notification timing etc.) | Lit review recommends; needs real usage data first | v2, after 4+ weeks of baseline |
| Macro Shortcuts library (capture from anywhere) | Siri Shortcut works; richer Shortcuts gallery is polish | v1.1 |
| Bank/finance sync (Plaid) | High value for Money domain but real engineering + credentials risk | v2 |
| Apple Health integration (read sleep, weight, activity) | Huge value-add for Health domain; deferred to keep overnight scope sane | v1.1 (top priority) |
| Native Mac companion app | iPhone is canonical; Mac is build env. CloudKit sync would enable later | v2 |

## 22. Open questions for you to push back on

Concrete points where I made calls that you should explicitly bless or override:

1. **EventKit (iCloud) over Google Calendar for v1.** Saves ~2 hours of OAuth + sync. You give up GCal write integration in v1. Override if you actively use GCal as authority.
2. **Voice capture IN v1 (WhisperKit).** Adds ~1 hour, adds 1.5GB to app size, but is the single highest-leverage friction reduction. Override if you want a leaner first build.
3. **Pre-seed only Health.** Other domains are spawnable from chat but not pre-built. Override if you want Home/Money also pre-built — adds maybe 30 min each.
4. **`NLEmbedding` over Core ML BGE-small for v1.** NLEmbedding is built into iOS and zero-setup; BGE-small gives better retrieval but adds Core ML conversion. Upgradeable in place. Override only if you've used BGE before and want it from day one.
5. **Foundation Models temperature default 0.7.** Settings exposes it; can override per domain in v1.1.
6. **Notification cap 3/day, 90min spacing.** Defaults per the JITAI evidence. Easy to change in Settings; locking in defaults so the build proceeds.
7. **Undo for v1 is per-action.** Not full replay-to-state. Override if you want full event-log replay (much bigger build).

## 23. North star

If after two weeks of real use the user says **"I had a bed-rot day last Thursday and Steward made Friday morning legible and easy to restart without me having to remember anything,"** v1 succeeded.

If after two weeks the user says **"I forgot to open it for 4 days and now I'm afraid to,"** v1 failed and the recovery design needs immediate work.
