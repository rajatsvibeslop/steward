# UI Rework v1.5 — Architecture Impact Analysis

> Companion to the v1.5 Authy-style landing rework. Designer owns visual layout; UXR owns user-journey copy and tile sequencing; this doc owns the *data-flow and code-shape consequences*. Cite line numbers when making claims.
>
> Tag baseline: `v0.9.6-sunday-morning`. All code references are against `main` at that tag.

---

## 0. One critical correction to the premise

The team-lead briefing assumes a `messages` table interleaving coordinator + domain turns. **There is no such table.** Chat history derives from `events` (see `ios/Steward/DB/Migrations.swift:68–88`). The events table already carries a nullable `domain TEXT` column (`Migrations.swift:73`) plus an index `events_domain ON events(domain, created_at)` (`Migrations.swift:85`). It is also append-only (`events_no_update` / `events_no_delete` triggers at `Migrations.swift:108–122`).

The "logical filter vs separate threads" choice therefore has a near-zero migration cost on Option A and a real schema-add cost on Option B. That tilts the call.

`NotificationActionContext` (see `ios/Steward/Notifications/NotificationActionRouter.swift`) already has typed `domain: String?`, `instrumentID: InstrumentID?`, `commitmentID: CommitmentID?` fields — deep-link plumbing for tile routing is already in the data, just unused by the navigation layer.

---

## 1. Conversation threading model — **Option A (logical filter on `events.domain`)**

### Recommendation: A. Definitively.

**Why:** the data model already implements A. Every event row has `domain TEXT` (nullable). The decision is which UI surface reads what slice.

| Concern | Option A (filter on `events.domain`) | Option B (new `conversation_id` column) |
|---|---|---|
| Migration | **None.** Column exists; index exists. | New column on `events` + new index + backfill for existing rows. Hits append-only triggers — requires careful `ALTER TABLE` (allowed) but no row backfill (the BEFORE-UPDATE trigger fires). Existing rows would have `conversation_id IS NULL` forever; UI would still need a fallback. |
| Cross-domain insight | Trivial — query without domain filter or with `IN (...)`. Coordinator chat reads `WHERE domain IS NULL`; weekly review reads `WHERE domain IS NOT NULL`. | Requires deliberate join across conversation_ids. Cross-domain insight becomes a special case, not a default. |
| Undo / audit | Unchanged. `AuditLog` queries events by `actor LIKE 'agent:%' OR actor='coordinator'`; that query is orthogonal to threading. | Unchanged for undo, but the audit log view needs to decide whether to be per-thread or global. Friction. |
| Memory retrieval | Already supported — `MemoryRetriever.search(domain: String? = nil)` (see line 60) takes optional domain. Per-tile retrieval = pass the tile's domain. | Same support, but `conversation_id` is orthogonal to `domain` so retrieval has to pick which to filter on. Two grouping axes is worse than one. |
| FM token budget | Smaller per-tile transcripts naturally — `WHERE domain = ?` filter shrinks the history slice fed into `PromptAssembler.assemble`. Same answer in Option B but free in Option A. | Same. |
| Determinism | Same SQL filter both ways; both deterministic. | Same. |

**The only thing Option B buys** is a way to represent two *separate* chats with the *same* domain agent (e.g., archive a prior conversation, start a new one). That's a v1.6+ feature at earliest, and even then a `WHERE created_at > <last_archive_ts>` filter handles it.

### Threading semantics in v1.5

- **Coordinator chat box** (top of grid): `WHERE domain IS NULL ORDER BY created_at DESC LIMIT 50` (with paging).
- **Domain tile chat**: `WHERE domain = ? ORDER BY created_at DESC LIMIT 50`.
- **User message attribution**: a user message typed in tile `health` writes `INSERT INTO events (actor='user', domain='health', kind='log_entry'|'chat_turn', ...)`. Typed in coordinator: `domain=NULL`. The chat surface stamps the domain at insert; no inference required.

**Edge case — handoffs in coordinator chat (UXR-resolved):** when the coordinator hand-offs to `health` (via `AgentHandoffTool`, see `AgentLoop.swift:438–493`), the resulting domain-agent reply currently doesn't write to events (the response is in-band JSON for the coordinator's tool result). For v1.5, the handoff result MUST emit an event with `actor='agent:health'`, **`domain=NULL`** — the chat turn lives in the **coordinator thread** (where the conversation is happening), not in the Health tile. The `actor` column still reflects who emitted it (so the bubble can show "Health agent says: …"), but the `domain` column determines thread placement, not authorship. **Action item — see §9.**

### Disambiguation — `events.domain` is overloaded but consistent per-kind

UXR's per-team conversation isolation (semantic isolation, not separate tables) means `events.domain` carries one of two meanings, distinguishable by `events.kind`:

| Event kind | What `domain` means | Examples |
|---|---|---|
| `chat_turn` | **Thread placement.** Which chat surface renders this as a bubble. NULL = coordinator chat; set = tile chat. | User message, coordinator reply, domain agent reply (whether via handoff or direct-to-tile) |
| `log_entry`, `instrument_update`, `commitment_create`, `notification_sent`, `calendar_write`, etc. | **State scope.** Which domain's state was mutated. NULL = cross-domain or coordinator-emitted; set = that domain's state changed. | An `instrument_update` from Sleep's tracker always has `domain='sleep'` regardless of whether the turn originated in the coordinator chat or the Sleep tile chat. |

Concrete: when coordinator hands off to Health and Health emits `instrument.apply_event`, the events table receives TWO rows:
- `(actor='agent:health', kind='instrument_update', domain='health')` — state change scoped to health
- `(actor='agent:health', kind='chat_turn', domain=NULL)` — reply rendered in coordinator chat

These are different rows with different `domain` semantics but they don't conflict because they have different `kind` values and serve different UI surfaces (Sheet tab vs Chat tab).

### Filter rules (concrete SQL clauses)

| UI surface | Filter |
|---|---|
| Coordinator landing chat | `WHERE domain IS NULL AND kind IN ('chat_turn', 'handoff_summary')` |
| `<team>` tile Chat tab | `WHERE domain = ? AND kind = 'chat_turn'` |
| `<team>` tile Sheet tab — instruments grid | derived from `instruments WHERE domain = ? AND archived_at IS NULL` + `events WHERE domain = ? AND kind = 'instrument_update' ORDER BY created_at DESC` |
| `<team>` tile Sheet tab — events disclosure | `WHERE domain = ? AND kind != 'chat_turn' ORDER BY created_at DESC LIMIT 50` |
| Coordinator's prompt runtime-context (recent events summary fed into LLM) | `WHERE kind != 'chat_turn' OR (kind = 'chat_turn' AND domain IS NULL)` — coordinator sees ALL state changes everywhere, but NEVER tile-private chat turns. This is the IA-enforced privacy boundary UXR (2) asks for. |
| Audit log (Settings → Activity) | `WHERE (actor LIKE 'agent:%' OR actor='coordinator') AND json_extract(payload_json, '$.turn_action') IS NOT NULL` — unchanged from v1; orthogonal to thread placement. |

---

## 2. AgentLoop scoping — direct-to-domain inside tiles

### Recommendation: when user is inside a domain tile's Chat, message bypasses coordinator and runs directly against that domain agent.

**Why:**
- The user has already made the routing decision (chose the tile). Re-asking the coordinator to "route this" is wasted hops + tokens + latency.
- It eliminates a class of mis-routing failure where coordinator decides "this is actually a Health thing" and hands off back to itself.
- It matches the Authy mental model: tile = focused conversation with that specific agent.

### Required code shape

`AgentLoop` today only exposes `run(userMessage:)` (`AgentLoop.swift:152`) which starts with the coordinator. Add:

```swift
extension AgentLoop {
    /// Run one user turn directly against the named domain agent, skipping
    /// the coordinator's routing pass. Used when the user is already inside
    /// the domain's chat surface.
    public func runDomainTurn(domain: String, userMessage: String) async throws -> DomainResponse {
        let turnID = TurnID(rawValue: turnIDGen())
        let now = clock()
        let (mercy, pauseUntil) = await settingsReader(now)

        guard let agent = await resolver.resolve(domain: domain) else {
            throw AgentError.domainNotFound(domain)
        }

        // Per-turn budget. Domain-direct turns still get 8 handoffs in case
        // the agent needs to consult cross-domain via a future tool; v1.5
        // domain agents do not expose agent.handoff in their scope so this
        // is mostly headroom.
        let sharedBudget = SharedBudget(budget: TurnBudget(
            handoffsRemaining: TurnBudget.defaultHandoffs,
            contextTokenCeiling: TurnBudget.domainTokenCeiling,
            startedAt: now
        ))

        let runtime = RuntimeContext(/* domain-scoped */ ...)
        let prompt = agent.systemPrompt(runtime: runtime)
        let tools = await registry.tools(in: agent.scope.allowedTools)

        let session = try await factory.makeSession(
            systemPrompt: prompt.text,
            tools: tools,
            temperature: temperature
        )
        let reply = try await session.respond(to: userMessage)
        return DomainResponse(domain: domain, text: reply.text, toolInvocations: reply.toolInvocations)
    }
}

public struct DomainResponse: Sendable {
    public let domain: String
    public let text: String
    public let toolInvocations: [LLMToolInvocation]
}
```

Note: domain agents today do not expose `agent.handoff` in their scope (`AgentLoop.swift:468–471`). That stays. If a user inside a tile asks something cross-domain, the agent's role prompt should suggest "ask the coordinator." v1.6 can add explicit `request_coordinator_consult` if needed.

### Persistence by surface

| Where user types | `events.actor` (user) | `events.domain` | Coordinator runs? | Domain-direct runs? |
|---|---|---|---|---|
| Coordinator chat box | `user` | `NULL` | yes | only via handoff tool |
| `health` tile chat | `user` | `health` | no | yes |
| `money` tile chat | `user` | `money` | no | yes |

---

## 3. PromptAssembler — per-domain runtime context

`PromptAssembler.assemble(for: AgentRole, ...)` already branches `.coordinator` vs `.domain(d)` (visible at `PromptAssembler.swift:124, 130, 162, 183, 247`). Per-domain context expansion is a small extension to the `.domain` branch:

```swift
// Inside PromptAssembler.assemble, .domain(let domain) case:
//
// Today emits: identity preamble, anti-moralization invariant, the domain's
// role_prompt, runtime context (mercy/pause/active domains), tool catalog,
// closing invariant.
//
// For v1.5 direct-to-domain turns, EXPAND the runtime context segment with:
//
//   • Domain's instrument summaries (kind, name, last value, vs target)
//     — read by Pod E's InstrumentDisplay logic + serialized to one-line
//   • Domain's events in last 24h, count + 1-line abstract per kind
//     (e.g., "3 log_entry, 1 instrument_update")
//   • Domain's open commitments (titles + due dates)
//   • DROP the coordinator-empty-state copy (it's nonsensical inside a
//     domain agent's context)
//   • DROP the active-domains list (the agent is already inside its domain;
//     mentioning siblings is noise)
```

Concretely: extend `RuntimeContext` (the struct passed in at line 177 of `AgentLoop.swift`) with three optional fields:
```swift
public struct RuntimeContext: Sendable {
    // ... existing fields ...
    /// Set only for direct-to-domain turns; coordinator turns leave nil.
    public let domainInstrumentSummaries: [InstrumentSummary]?
    public let domainRecentEventsAbstract: String?
    public let domainOpenCommitments: [CommitmentSummary]?
}
```

`PromptAssembler` reads them in the `.domain(let d)` runtime-context-segment builder and emits a "what's the state of this domain right now" paragraph at fixed position (after the role_prompt segment, before the tool catalog). Position 3.5 in the §1.7 ordering, BETWEEN the user-editable role_prompt and the tool catalog. The closing invariant at position 6 still wins per §1.7.

**Don't** add a new segment type or invariant marker. The existing structure handles this.

### Coordinator runtime context — IA-enforced privacy from tile chats

UXR (2) requires the coordinator NEVER read raw tile transcripts — only the event log and admitted memory items. This is enforced by the recent-events-summary filter (see §1 filter rules table):

```sql
-- Inside ContextAssembler when role = .coordinator:
SELECT actor, kind, domain, text, created_at
FROM events
WHERE created_at > ?
  AND (kind != 'chat_turn' OR (kind = 'chat_turn' AND domain IS NULL))
ORDER BY created_at DESC
LIMIT 50
```

The coordinator sees: all state changes everywhere, all coordinator-thread chat turns. The coordinator does NOT see: tile-private chat dialogue. Admitted memory items still flow through `MemoryRetriever.search(domain: nil, ...)` (no domain filter for coordinator).

Add this assertion to `ContextAssembler` (or wherever the recent-events summary is built — currently `AgentLoop.swift:186` passes `recentEventsSummary: nil`, so the slot exists; implementation owes the SQL).

---

## 4. TurnBudget — already per-turn; just confirm semantics

Reading `AgentLoop.swift:198–204` carefully: `SharedBudget(budget: TurnBudget(handoffsRemaining: defaultHandoffs, ...))` is constructed **inside** `run(userMessage:)` on every call. The budget IS per-turn today, not per-app-session. (The actor wrapper protects against multi-tool-call concurrency *within* one turn.)

For v1.5: same model. Per-turn (per `run` / `runDomainTurn` call), 8 handoffs each. Domain-direct turns also get 8 even though current domain scope doesn't expose handoff — headroom for v1.6.

**No code change required for v1.5.** Just document the invariant explicitly in `TurnBudget.swift` header so future-Rajat doesn't accidentally hoist `sharedBudget` to instance state.

---

## 5. ChatViewModel — one VM per thread

### Recommendation: one `ChatViewModel` per active thread, parameterized at init.

Today, `ChatViewModel` is a single class (`ChatViewModel.swift:60`). For v1.5:

```swift
public enum ChatThread: Hashable, Sendable {
    case coordinator
    case domain(DomainID)

    var domainFilter: String? {
        switch self {
        case .coordinator: return nil
        case .domain(let id): return id.rawValue
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending: Bool = false
    @Published private(set) var backendKind: LLMBackendKind?
    @Published private(set) var lastError: String?

    let thread: ChatThread                  // NEW — set at init, immutable

    // existing dependencies...
    private let provider: DatabaseProvider
    private let domainStore: DomainStore
    private let clock: @Sendable () -> Date
    private let permissionFlow: any PermissionFlowGateway

    init(
        thread: ChatThread,                 // NEW required arg
        provider: DatabaseProvider = .shared,
        domainStore: DomainStore = .shared,
        clock: @escaping @Sendable () -> Date = { Date() },
        permissionFlow: any PermissionFlowGateway = LivePermissionFlowGateway()
    ) {
        self.thread = thread
        self.provider = provider
        // ...
    }

    func send(_ raw: String) async {
        // ... existing prelude ...
        let ready = try await AgentLoopHost.shared.ready()
        let response: CoordinatorResponse | DomainResponse
        switch thread {
        case .coordinator:
            response = .coord(try await ready.loop.run(userMessage: text))
        case .domain(let id):
            response = .domain(try await ready.loop.runDomainTurn(domain: id.rawValue, userMessage: text))
        }
        // ... append reply ...
    }

    private func loadMessageHistory() async {
        // Filter events by thread.domainFilter
        let sql = thread.domainFilter == nil
            ? "SELECT ... FROM events WHERE domain IS NULL AND kind IN ('chat_turn', 'agent_reply') ORDER BY created_at DESC LIMIT 50"
            : "SELECT ... FROM events WHERE domain = ? AND kind IN ('chat_turn', 'agent_reply') ORDER BY created_at DESC LIMIT 50"
        // ...
    }
}
```

### Why one-VM-per-thread over single-VM-with-thread-param

- SwiftUI ergonomics: `@StateObject ChatViewModel(thread: .domain(d))` in each tile's chat view. View lifecycle = VM lifecycle. Clean.
- Each VM holds its own `messages` buffer — no filtering at render time, no recompute on tab switch.
- Memory cost is trivial: ~470-line class × at most 6–8 active VMs (coordinator + ≤7 domain tiles + maybe an open instrument detail).
- Permission flow state (the per-message permission-required cards) is naturally per-thread, not global.

### Coordinator VM lifetime quirk

The coordinator VM should live for the whole app session (its chat persists across tile navigations). Use a single `@StateObject ChatViewModel(thread: .coordinator)` at the AgentGridView root, NOT recreated per render. Domain tile VMs can be `@StateObject` inside `DomainDetailView` and discarded on dismiss — acceptable since their history reloads from `events` quickly.

---

## 6. NotificationActionContext — already domain-aware; just wire navigation

`NotificationActionContext` (in `ios/Steward/Notifications/NotificationActionRouter.swift`) already carries:
- `kind: NotificationKind`
- `domain: String?`
- `instrumentID: InstrumentID?`
- `commitmentID: CommitmentID?`
- `suggestedPrompt: String?`

No migration. No new field. v1.5 just changes the tap handler in the UI to:

```swift
// In NotificationActionRouter's tap handler -> UI bridge:
switch context.domain {
case nil:
    appRouter.open(.coordinatorChat(prompt: context.suggestedPrompt))
case .some(let domain):
    appRouter.open(.domainTile(domain: domain, tab: .chat, prompt: context.suggestedPrompt))
}
// If context.instrumentID is also set, deep-link to that instrument's
// detail (the Sheet tab of the domain tile, scrolled to the instrument).
```

**In-flight scheduled notifications:** zero migration. Old-format scheduled notifications either have `domain` set (route to tile) or `domain=nil` (route to coordinator). Identical behavior in both pre-v1.5 and post-v1.5 builds, just with different default landing.

---

## 7. Memory retrieval scope — per-tile, with no special boost

`MemoryRetriever.search(query:, domain: String? = nil, ...)` already supports it (`MemoryRetriever.swift:60`). v1.5 wiring:

| Surface | `domain:` arg | Rationale |
|---|---|---|
| Coordinator chat | `nil` | True cross-domain context — user is talking to the routing layer |
| `<X>` tile chat | `X` | Domain-focused conversation; cross-domain memories are noise |
| Morning brief (if retained) | `nil` | Brief inherently spans domains |

**Do not add a "domain-bonus from global" scoring path** unless usage data shows tile-confined retrieval missing important context. Adding it later is one line in the reranker; removing it once shipped is harder. Default conservative.

---

## 8. Migration strategy — none required

No `messages` table. Existing `events` rows have correct `domain` values (NULL for coordinator turns, set for domain-agent emissions). The v1.5 UI changes the *query*, not the data.

**Concrete v1.5 migration script: empty.** No `registerMigration` call needed.

One operational note: existing chat turns from `actor='user'` likely all have `domain=NULL` (since they typed in the old single Chat tab, which only knew the coordinator). They will appear in the coordinator chat box only. The user will not see them in any domain tile. That's correct — they never said "this is a Health message" because no such UI existed. No backfill.

---

## 9. Tier-1 invariant surfaces at risk → route through nemesis pre-merge

| Surface | Change | Why nemesis-worthy |
|---|---|---|
| **AgentLoop** | Add `runDomainTurn(domain:userMessage:)` method | Adds a second entry point. Risk: divergence from `run(userMessage:)` behavior (settings reads, mercy mode, per-turn budget construction). Must mirror exactly. |
| **PromptAssembler** | Extend RuntimeContext + add domain-state paragraph in `.domain` branch | Touches the prompt that domain agents see. Anti-moralization invariants must remain wrapped in `<<INVARIANT>>` markers and still appear FIRST and LAST per §1.7. Closing override-suppression invariant cannot move. |
| **events insertion contract** | Chat surface stamps `domain` on user messages | Risk: a tile chat accidentally inserts with `domain=NULL`, leaking the message into the coordinator stream. Single chokepoint helper `EventLog.insertChatTurn(actor:domain:text:turnID:)` to enforce. |
| **AgentHandoffTool** | Emits an `events` row for the domain reply (currently in-band only) | Risk: double-emission if coordinator and handoff both write. Single emission, at handoff-tool boundary, with `actor='agent:<domain>'`, `domain=<domain>`, `reasoning=<from handoff args>`. |
| **Notification deep-link routing** | UI honors `context.domain` for navigation | Risk: tap context loss. The router already exists and is hard-rejection guarded (`malformed(reason:)` instead of silent fallback) per the file header — the UI bridge must not regress that. |

**NOT touched** — these stay frozen:
- `InstrumentKind` protocol + 7 conformances (§1.2)
- `InstrumentRegistry` dispatch
- `NotificationScheduler` actor (§1.3) — cap math, mercy mode, RRule expansion
- `EventKitGateway` (§1.9) — permission hybrid model
- `MemoryAdmissionPolicy` (§1.5) — dedup + contradiction detection
- `UndoExecutor` + `InverseAction` enum (§1.6) — audit unchanged
- `SettingsStore` (§1.11)
- `TurnBudget` struct surface (§1.1) — semantics already per-turn; just document

---

## 10. Minimal first cut — what ships v1.5 without breaking v1

### Ships in v1.5

1. **`AgentGridView` as root.** Replaces `RootTabView`. Layout: coordinator chat box (3 lines visible, expandable), domain tile grid below (one tile per row in `domains WHERE archived_at IS NULL`), gear icon in nav bar.
2. **`DomainTileView`** — name, color from `DomainColor`, last-event-timestamp summary, optional unread badge (events emitted by that domain since last visit; cheap row count).
3. **`DomainDetailView`** — internal `TabView(Chat | Sheet)`.
4. **Coordinator chat** — existing `ChatViewModel(thread: .coordinator)` behind the AgentGridView's top chat box. Same `AgentLoop.run(userMessage:)` path. Zero behavior change from v1.
5. **Domain tile Chat tab** — new `ChatViewModel(thread: .domain(d))`. New `AgentLoop.runDomainTurn(domain:userMessage:)` path. Domain-scoped memory retrieval.
6. **Domain tile Sheet tab** — existing Pod E `InstrumentDisplay` filtered by domain + events list `WHERE domain = ?`.
7. **Gear-icon overlay** — existing `SettingsView` presented as `.sheet`.
8. **Notification tap routing** — UI bridge reads `NotificationActionContext.domain` and navigates to either coordinator or tile.
9. **PromptAssembler domain-context expansion** — instrument summaries + recent events + open commitments in the `.domain` runtime context.
10. **AgentHandoffTool emits a `chat_turn` event** for the domain reply with `actor='agent:<domain>'` and **`domain=NULL`** (UXR-resolved: handoff replies render in the coordinator chat where the conversation originated, NOT in the destination tile). The handoff tool ALSO continues to permit the called agent's tool invocations to emit their own state-change events with `domain=<destination>` — those rows are independent and flow to the tile's Sheet tab.
11. **Tile cross-domain deflection** — domain agents whose role prompt detects an out-of-scope question reply with the verbatim UXR-supplied "back out and ask Steward" line. The tile UI renders a one-tap chip on that reply that copies the user's last message into the coordinator chat draft (does not auto-send; user reviews + presses send). No new agent capability needed — the deflection is role-prompt copy + a UI affordance.
12. **`+ Spawn a team` CTA tile** in the agent grid — tapping it pre-fills coordinator chat with the v2 Branch B opener phrase (per UXR §6). Coordinator's existing empty-state Branch B flow handles spawn from there. No new code in `AgentLoop`.

### Defers to v1.6

- **Today tab restoration as a surface.** Morning brief still fires as an `events` row with `kind='morning_brief'` — for v1.5, surface it inside the coordinator chat as a special card on first open of the day, OR as a banner on AgentGridView. No standalone tab.
- **Cross-domain consult from inside a tile.** Domain agents stay scoped per v1; if user wants cross-domain, the role prompt suggests "ask the coordinator." Explicit `request_coordinator_consult` tool is v1.6+.
- **Per-domain unread-since-last-visit badge persistence.** v1.5 computes on the fly from `events WHERE domain = ? AND created_at > <last_view_ts>` where `last_view_ts` lives in a new tiny `domain_view_state` table (or `settings_json` blob if we're lazy). v1.5 can skip the badge entirely and just show last-event-timestamp instead — cleaner.
- **Voice button inside domain tile chat.** Same `VoiceCapture` protocol; wire same way; minor work but not critical.
- **Tile archiving and reordering UI.** v1.5 uses domain creation order; archive via existing Settings → Life Teams flow.
- **Multi-conversation per domain.** If user wants "new chat with health," that's v1.6 (likely via the `conversation_id` column then — but no need to add it yet).

### Definition of done

The v1.5 first cut is complete when:
1. App launches into `AgentGridView`. Coordinator chat box visible at top, all active domain tiles below.
2. Typing in coordinator chat box behaves identically to v1's Chat tab.
3. Tapping a tile opens `DomainDetailView`; default tab is Chat.
4. Typing in tile chat goes through `runDomainTurn`; reply appears in the same tile only; `events` row carries `domain=<that>` for both user and agent messages.
5. Switching to Sheet tab shows that domain's instruments + recent events.
6. Tapping a notification with `context.domain != nil` opens that tile's Chat with `suggestedPrompt` pre-filled.
7. Tapping a notification with `context.domain == nil` opens coordinator chat with `suggestedPrompt` pre-filled.
8. Gear icon opens Settings as a sheet; all v1 Settings functionality intact.
9. AuditLog (Settings → Activity) shows events from all domains, no regression.
10. Undo from AuditLog still works against domain-emitted events (UndoExecutor unchanged).

---

## Appendix A — code touchpoints summary

| File | Change |
|---|---|
| `Agent/AgentLoop.swift:152` (existing `run`) | unchanged; reused for coordinator |
| `Agent/AgentLoop.swift` (new method) | add `runDomainTurn(domain:userMessage:) async throws -> DomainResponse` |
| `Agent/AgentLoop.swift:438–493` (`AgentHandoffTool.invoke`) | emit `events` row at handoff completion with `domain=<args.domain>`, `actor='agent:<args.domain>'`, `reasoning=<args.message>` so the result appears in the destination tile |
| `Agent/AgentTypes.swift` | extend `RuntimeContext` with optional domain-state fields (instruments, recent events, commitments) |
| `Agent/PromptAssembler.swift:130, 183, 247` (`.domain` branches) | emit new domain-state paragraph between role_prompt and tool catalog when fields are non-nil |
| `Agent/TurnBudget.swift` (header comment only) | document per-turn invariant explicitly; no code change |
| `Views/Chat/ChatViewModel.swift` | add `thread: ChatThread` required init arg; filter `messages` query by `thread.domainFilter`; switch `send` to call `run` or `runDomainTurn` per thread |
| New: `Views/Root/AgentGridView.swift` | new root view |
| New: `Views/Root/DomainTileView.swift` | tile cell |
| New: `Views/Domain/DomainDetailView.swift` | tabbed Chat + Sheet |
| New: `Views/Domain/DomainSheetView.swift` | instrument list + events table |
| `Views/Root/RootTabView.swift` | DELETE (replaced by AgentGridView) |
| `Notifications/NotificationActionRouter.swift` | unchanged; UI bridge reads `domain` field |
| New: UI bridge in `App` or `AgentGridView` | switch on `NotificationActionContext.domain` for tap navigation |
| `Memory/MemoryRetriever.swift:60` | unchanged; just pass thread's domain at call sites |
| `DB/Migrations.swift` | unchanged; no new migration |
| `DB/EventLog.swift` | add `insertChatTurn(actor:domain:text:turnID:)` chokepoint helper so tile chats can't accidentally write `domain=NULL` |

Total estimated impl effort: 1 well-budgeted pod, ~3–5 hours given the existing scaffolding.

---

## Appendix B — UXR convergence (RESOLVED)

UXR's `design/ui-rework-v1.5-journey.md` answered the open questions:

1. **Coordinator-handoff reply placement → (a) coordinator chat only.** Resolved per UXR §2 ("per-team conversation isolation") + team-lead reconciliation. Handoff reply event is written with `actor='agent:<dest>'`, `domain=NULL`, `kind='chat_turn'` so it renders in the coordinator chat where the conversation originated. The destination tile's state-change events (instrument_update, etc.) still flow to its Sheet tab via the standard `domain=<dest>` stamp on those rows.
2. **Morning brief surface — open question, neutral arch.** UXR did not specify; designer to choose between coordinator-chat card and tile-grid banner. Both are zero-impact on data layer.
3. **Empty tile Sheet tab — UXR §5 specifies all instruments-as-grids with events as collapsed disclosure below.** If a tile has zero instruments, the Sheet tab shows an "ask Steward to set up instruments" affordance — pre-fills coordinator chat with the relevant spawn phrase. No state-changing UI inside the tile.
4. **Tile chat deflection copy — see UXR §4** (verbatim "back out and ask Steward" line + one-tap chip).
5. **Spawn flow — see UXR §6** (typed phrase OR `+ Spawn a team` CTA tile both run v2 Branch B; coordinator owns).

---

## Appendix C — `agent.cross_consult` tool (proposed by UXR; recommend DEFER to v1.6)

UXR proposed a new `agent.cross_consult` tool for "when one agent needs context from another." Below is the spec; **arch recommendation is to defer wiring this in v1.5** for the reasons below the spec.

### Proposed tool spec

```swift
/// Domain-to-domain read-only consultation. The calling agent stays in
/// control of its turn and gets a structured summary back from the
/// consulted agent without transferring control. Distinct from
/// agent.handoff which transfers the turn entirely.
public struct AgentCrossConsultTool: LLMTool {
    public let id: String = "agent.cross_consult"
    public let description: String = """
        Ask another domain agent a read-only question and get a structured
        summary in return. Use when you need context from another domain
        but want to keep control of the current turn (e.g., Sleep agent
        consulting Workout state to answer a "should I work out tomorrow"
        question). Counts one budget hop.
        Args: {domain: string, question: string, max_response_chars: int}
        """
    public let jsonSchemaForArgs: String = #"""
        {
          "type": "object",
          "properties": {
            "domain": {"type": "string"},
            "question": {"type": "string"},
            "max_response_chars": {"type": "integer", "minimum": 100, "maximum": 1500}
          },
          "required": ["domain", "question"]
        }
        """#

    public func invoke(argsJSON: String) async throws -> String {
        // Consume one budget hop (cross_consult and handoff share the
        // per-turn handoff budget — both transfer one full LLM call).
        try await budget.consumeHandoff()
        guard let agent = await resolver.resolve(domain: args.domain) else {
            return errorJSON(kind: "domain_not_found", detail: args.domain)
        }
        // Build a READ-ONLY tool scope for the consulted agent: only
        // instrument.read / event.list / memory.search / instrument.list.
        // The consulted agent CANNOT mutate state during a cross_consult.
        let readOnlyTools = await registry.tools(in: AgentScope.readOnlySubset)
        let prompt = agent.systemPrompt(runtime: runtime.asConsultedReadOnly())
        let session = try await factory.makeSession(
            systemPrompt: prompt.text,
            tools: readOnlyTools,
            temperature: temperature
        )
        let reply = try await session.respond(to: args.question)
        // Emit a chat_turn event with domain=NULL and a special kind so
        // the cross_consult is auditable but doesn't appear in chat surfaces.
        // (kind='cross_consult_record' — new kind; UI filters skip it.)
        try await auditLog.recordCrossConsult(
            initiator: caller, consulted: args.domain, summary: reply.text
        )
        return jsonResult(summary: String(reply.text.prefix(args.maxResponseChars ?? 800)))
    }
}
```

### Why defer to v1.6 (not v1.5)

1. **UXR §4 already handles cross-domain UX via tile deflection.** The user is told "back out and ask Steward" — coordinator does the consultation via existing `agent.handoff`. No new tool needed for the demo user journey.
2. **Adds prompt-education surface area.** Domain agents would need their role prompts updated to "you may consult another agent via agent.cross_consult when …" — risk of agents over-consulting (every Health question triggers a Sleep consult) or under-consulting (never finding the right moment). Needs real usage data to tune.
3. **Adds budget-accounting complexity.** Cross_consult and handoff both consume per-turn hops; sharing the budget is correct but the rationale needs documenting and testing.
4. **Adds a new event kind** (`cross_consult_record`) and the per-surface filter rules in §1 need an additional clause to skip it. Minor but more surface area.
5. **3–5h budget for v1.5.** This adds ~1.5h (tool impl + tests + prompt updates + filter rules). Pushes the cut over budget.

**If v1.5 needs it after all:** wire only on coordinator scope first (not domain scope) so domain agents can't consult each other directly — coordinator can use it as a lightweight alternative to full handoff. That's a smaller surface (one scope, no agent-to-agent prompt education needed) and ~30 min of impl.

Updates if added in v1.5 minimal cut:
- §1 filter table: add `AND kind != 'cross_consult_record'` to coordinator-chat and tile-chat filters
- §9 risk table: add row "cross_consult mis-routing — domain-agent over-consultation"
- §10 first cut: add as item 13
- Appendix A: add `AgentCrossConsultTool` to `AgentLoop.swift` and `ToolID` enum case to scope tables
