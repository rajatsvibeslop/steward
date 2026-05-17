# Steward

A single-user, offline-first iOS app that acts as a **personal institutional layer**: a coordinator agent plus per-domain sub-agents that take ownership of the maintenance work for your foundational life systems — sleep, money, home, therapy follow-through, hobbies, whatever you ask it to carry.

Agents have full autonomy to log events, update spreadsheet-style instruments, schedule local notifications, write to Calendar and Reminders, and persist memory across sessions. Every external action is logged with the agent's reasoning so it's auditable and reversible. Inference runs on-device via Apple Foundation Models, so the coordinator works on the subway.

Full design: [`spec.md`](spec.md).

## Status — v1

All six build tracks merged to `main`. Build green on simulator. The app is intended for **a single user (Rajat) on a single iPhone**.

| Track | What it covers |
|---|---|
| A | Xcode project scaffold, GRDB schema, FTS5 |
| B | Foundation Models integration, coordinator + domain agents, multi-hop turn loop, empty-state script |
| C | Tool implementations (events, instruments, commitments, memory + hybrid retrieval) |
| D | EventKit (Calendar + Reminders), notifications with cap enforcement, recurring rules |
| E | SwiftUI (Chat, Today, Settings tabs) |
| F | WhisperKit voice capture, iCloud Drive CSV mirror |

Foundation Models is gated behind a protocol (`LLMSession` / `LLMResolver`). Without Xcode 26 beta installed, the resolver falls back to `MockLLMSession` and stamps a `STUB` chip on every reply. With Xcode 26 beta + the iOS 26 deployment target + Apple Intelligence enabled on a supported device, the real on-device model is used automatically.

## Build + deploy

Full step-by-step including Xcode 26 beta install, WhisperKit model fetch, deployment-target bump, signing, and the 14-item self-QA checklist: **[`docs/sunday-morning-startup.md`](docs/sunday-morning-startup.md)**. Read that first. Then, once the app is on your phone: **[`docs/first-morning.md`](docs/first-morning.md)** walks through what the coordinator will say and how to spawn your first team.

Short version:

1. Install **Xcode 26 beta** from developer.apple.com and point `xcode-select` at it.
2. Run `scripts/fetch-whisperkit-model.sh` (requires `git-lfs`) to bundle the WhisperKit model. Skip this to build without voice capture.
3. `open ios/Steward.xcodeproj`. Set **Minimum Deployments → iOS** to `26.0`. Build (⌘B).
4. Plug in iPhone (developer mode on), pick it in Xcode's target picker, ⌘R. Bundle ID is `com.rajatscode.steward`.

## What's in v1

- **Three tabs:** Chat (coordinator + voice), Today (active instruments + upcoming commitments + morning brief), Settings (quiet hours, notification cap, mercy/pause toggles, audit log with per-action undo).
- **Two-tier agent loop:** a coordinator the user chats with, and per-domain agents the coordinator hands off to. Both run on Apple Foundation Models with the same call shape; only the assembled system prompt and tool subset differ.
- **Seven instrument kinds:** running accumulator, bounded budget, rolling average, countdown commitment, weekly evidence log, checklist, bounded window. State is recomputed deterministically in Swift — the LLM never does instrument arithmetic.
- **Append-only event log** in SQLite (via GRDB). Every mutation to instruments / commitments / settings / calendar emits an event with the actor and reasoning.
- **Hybrid memory** — vector cosine (NLEmbedding) + FTS5 BM25 + recency + type weight, with strength decay on a nightly task.
- **Notification engine** with cap enforcement (max 3/day, 90-min spacing, quiet hours, mercy mode) done in Swift, not by the LLM. Recurring rules translate to `UNCalendarNotificationTrigger`.
- **EventKit** for Calendar and Reminders. Writes locally, syncs through iCloud transparently.
- **iCloud Drive CSV mirror** of every instrument and the monthly-partitioned event log. Edit in Numbers; `NSFileCoordinator` watches for changes and emits `manual_correction` events.
- **WhisperKit on-device voice capture** in the chat input. Hold to talk, release to insert transcript.
- **Empty-state coordinator script** — zero pre-seeded domains. First conversation either captures-first (type a concrete event) or setup-first (tap "walk me through it"). See [`design/coordinator-empty-state-v2.md`](design/coordinator-empty-state-v2.md).
- **Audit log + per-action undo** in Settings. Every agent calendar write, reminder, notification, instrument mutation is undoable.

## What's deferred to v1.1+

Listed here so you don't expect them. Full reasoning in [`spec.md`](spec.md) §21.

- Apple HealthKit (top of the v1.1 list)
- Google Sheets mirror (in-app grid + iCloud Drive CSV are the only spreadsheet surfaces in v1)
- Custom user-defined instrument kinds
- Multi-device sync via CloudKit
- Weekly review report (cross-domain pattern recognition)
- Background cron via webhooks
- Written-formula support (interpretation B from the spreadsheets discussion)
- Google Calendar mirror (EventKit / iCloud is the transport; subscribe to GCal in iOS Calendar settings to see GCal events through EventKit)
- Plaid / bank sync
- Native Mac companion app
- Web search (returns offline-error in v1)

## Repo layout

```
spec.md                          design spec (single source of truth)
docs/sunday-morning-startup.md   first-thing-Sunday startup runbook
design/                          coordinator empty-state script, UI specs
qa/                              regression checklist
research/, investigation/        lit review + design investigation notes
scripts/fetch-whisperkit-model.sh   bundles WhisperKit model into the app
ios/Steward.xcodeproj            Xcode project
ios/Steward/                     app source (Agent, Tools, Views, etc.)
ios/StewardTests/                unit + integration tests
```

## License

See [`LICENSE`](LICENSE).
