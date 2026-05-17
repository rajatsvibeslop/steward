//
//  Migrations.swift
//  Steward
//
//  Track A: GRDB DatabaseMigrator with the full v1 schema baked into a single
//  named migration. No production data exists yet, so additions defined in
//  the implementation-addendum (state_version, embedding_revision,
//  strength_at_last_update, last_strength_update_at, FTS5 triggers, etc.)
//  go into v1 directly instead of as later migrations.
//
//  Migrations are registered with `.foreignKeyChecks` enabled and use the
//  default GRDB behavior of running each migration inside a transaction, so
//  re-running on an existing DB is a no-op and never overwrites data.
//

import Foundation
import GRDB

enum Migrations {
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Erase on schema mismatch in DEBUG so iteration is fast. Production
        // (Release) never erases — migrations only add.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial_schema") { db in
            try createEventsTable(db)
            try createMemoryItemsTable(db)
            try createInstrumentsTable(db)
            try createCommitmentsTable(db)
            try createDomainsTable(db)
            try createNotificationsTable(db)
            try createSyncQueueTable(db)
            try createSettingsTable(db)
        }

        // v2 — Track D: NotificationScheduler.topUpHorizon needs persistent
        // recurring rules so the next 7+ days of notifications can be
        // re-issued on every foreground tick. Without this, BGTasks failing
        // in install week silently kills the morning brief. Pod A's v1 had
        // no rule-persistence table; v2 adds one. Additive, no production
        // data exists.
        migrator.registerMigration("v2_notification_recurring_rules") { db in
            try createNotificationRecurringRulesTable(db)
        }

        // v3 — Track C audit/undo patch: undo of `memory.save` /
        // `memory.forget` needs a single column to flip so the inverse is a
        // one-statement UPDATE that round-trips cleanly. Strength-based
        // soft-delete (strength=0) was lossy for restore — the original
        // pre-forget strength wasn't captured. archived_at gives us a
        // dedicated "hidden from retrieval" channel orthogonal to decay.
        // Additive column, NULL for every existing row → safe.
        migrator.registerMigration("v3_memory_items_archived_at") { db in
            try addMemoryItemsArchivedAtColumn(db)
        }

        return migrator
    }()

    // MARK: - events (append-only history)

    private static func createEventsTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE events (
                event_id      TEXT PRIMARY KEY,
                created_at    INTEGER NOT NULL,
                actor         TEXT NOT NULL,
                kind          TEXT NOT NULL,
                domain        TEXT,
                instrument_id TEXT,
                commitment_id TEXT,
                text          TEXT,
                payload_json  TEXT,
                source        TEXT,
                reasoning     TEXT,
                CHECK (actor IN ('user', 'system') OR reasoning IS NOT NULL)
            )
        """)
        try db.execute(sql: "CREATE INDEX events_created_at ON events(created_at)")
        try db.execute(sql: "CREATE INDEX events_domain ON events(domain, created_at)")
        try db.execute(sql: "CREATE INDEX events_instrument ON events(instrument_id, created_at)")

        // FTS5 virtual table over text + payload_json. content-shared with
        // events; insert-only trigger keeps it synced. events is append-only,
        // so DELETE / UPDATE triggers are intentionally absent.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE events_fts USING fts5(
                text,
                payload_json,
                content='events',
                content_rowid='rowid'
            )
        """)
        try db.execute(sql: """
            CREATE TRIGGER events_fts_ai AFTER INSERT ON events BEGIN
                INSERT INTO events_fts(rowid, text, payload_json)
                VALUES (new.rowid, new.text, new.payload_json);
            END
        """)

        // Hard reject #10: events is append-only forever. Enforce at the DB
        // level — RAISE(ABORT, ...) fires before the statement so the row
        // is untouched. Forgetting a memory writes a soft-delete event; it
        // never deletes the original event row.
        try db.execute(sql: """
            CREATE TRIGGER events_no_update BEFORE UPDATE ON events
            BEGIN
                SELECT RAISE(ABORT, 'events is append-only');
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER events_no_delete BEFORE DELETE ON events
            BEGIN
                SELECT RAISE(ABORT, 'events is append-only');
            END
        """)
    }

    // MARK: - memory_items (distilled retrievable facts)

    // Writer contract (no SQL DEFAULTs by design — convention belongs in the
    // record layer, not the schema):
    // - `created_at` and `last_strength_update_at` MUST be set on insert by
    //   the caller to `Int64(Date().timeIntervalSince1970 * 1000)`.
    // - `strength_at_last_update` defaults to 1.0 in SQL because that's the
    //   spec's "new memory" value; effective strength is computed lazily at
    //   query time via `MemoryItem.effectiveStrength(now:)` (addendum §1.5).
    private static func createMemoryItemsTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE memory_items (
                memory_id               TEXT PRIMARY KEY,
                type                    TEXT NOT NULL,
                text                    TEXT NOT NULL,
                embedding               BLOB NOT NULL,
                embedding_dim           INTEGER NOT NULL,
                embedding_revision      TEXT NOT NULL,
                strength_at_last_update REAL NOT NULL DEFAULT 1.0,
                last_strength_update_at INTEGER NOT NULL,
                last_accessed_at        INTEGER,
                created_at              INTEGER NOT NULL,
                expires_at              INTEGER,
                domain                  TEXT,
                provenance_event_ids    TEXT
            )
        """)
        try db.execute(sql: """
            CREATE INDEX memory_domain
            ON memory_items(domain, strength_at_last_update DESC)
        """)
        try db.execute(sql: """
            CREATE INDEX memory_strength_lazy
            ON memory_items(strength_at_last_update DESC, last_strength_update_at)
        """)
        // Pod C does an `embedding_revision != ?` sweep on launch (addendum
        // §2.3 lazy-rebuild). Index keeps that cheap.
        try db.execute(sql: "CREATE INDEX memory_embedding_revision ON memory_items(embedding_revision)")

        // FTS5 with full INSERT / DELETE / UPDATE triggers — memories mutate
        // (strength bumps, forgets, text rewrites).
        try db.execute(sql: """
            CREATE VIRTUAL TABLE memory_fts USING fts5(
                text,
                content='memory_items',
                content_rowid='rowid'
            )
        """)
        try db.execute(sql: """
            CREATE TRIGGER memory_fts_ai AFTER INSERT ON memory_items BEGIN
                INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, new.text);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER memory_fts_ad AFTER DELETE ON memory_items BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, text)
                VALUES ('delete', old.rowid, old.text);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER memory_fts_au AFTER UPDATE OF text ON memory_items BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, text)
                VALUES ('delete', old.rowid, old.text);
                INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, new.text);
            END
        """)
    }

    // MARK: - instruments (agent-maintained state machines)

    private static func createInstrumentsTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE instruments (
                instrument_id    TEXT PRIMARY KEY,
                domain           TEXT NOT NULL,
                kind             TEXT NOT NULL,
                name             TEXT NOT NULL,
                definition_json  TEXT NOT NULL,
                state_json       TEXT NOT NULL,
                state_version    INTEGER NOT NULL DEFAULT 1,
                created_at       INTEGER NOT NULL,
                last_updated_at  INTEGER NOT NULL,
                review_cadence   TEXT,
                archived_at      INTEGER,
                csv_mirror_path  TEXT
            )
        """)
        try db.execute(sql: """
            CREATE INDEX instruments_domain
            ON instruments(domain)
            WHERE archived_at IS NULL
        """)
    }

    // MARK: - commitments (promised actions)

    private static func createCommitmentsTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE commitments (
                commitment_id        TEXT PRIMARY KEY,
                title                TEXT NOT NULL,
                status               TEXT NOT NULL,
                due_at               INTEGER,
                decision_by          INTEGER,
                domain               TEXT,
                importance           TEXT NOT NULL,
                linked_instrument_id TEXT,
                created_at           INTEGER NOT NULL,
                completed_at         INTEGER,
                ek_reminder_id       TEXT,
                CHECK (status IN ('active', 'done', 'abandoned', 'snoozed')),
                CHECK (importance IN ('low', 'medium', 'high'))
            )
        """)
        try db.execute(sql: "CREATE INDEX commitments_status ON commitments(status, due_at)")
    }

    // MARK: - domains (life teams as runtime config)

    private static func createDomainsTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE domains (
                domain              TEXT PRIMARY KEY,
                display_name        TEXT NOT NULL,
                role_prompt         TEXT NOT NULL,
                tool_scope_json     TEXT NOT NULL,
                default_quiet_hours TEXT,
                created_at          INTEGER NOT NULL,
                archived_at         INTEGER
            )
        """)
    }

    // MARK: - notifications (schedule + audit)

    private static func createNotificationsTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE notifications (
                notification_id     TEXT PRIMARY KEY,
                scheduled_for       INTEGER NOT NULL,
                delivered_at        INTEGER,
                acted_at            INTEGER,
                outcome             TEXT,
                domain              TEXT,
                instrument_id       TEXT,
                kind                TEXT NOT NULL,
                title               TEXT NOT NULL,
                body                TEXT NOT NULL,
                action_context_json TEXT,
                un_request_id       TEXT,
                scheduled_by        TEXT NOT NULL,
                cancelled_at        INTEGER
            )
        """)
        try db.execute(sql: """
            CREATE INDEX notifications_scheduled
            ON notifications(scheduled_for)
            WHERE delivered_at IS NULL AND cancelled_at IS NULL
        """)
    }

    // MARK: - sync_queue (outbound external writes; v1 target = csv_mirror)

    private static func createSyncQueueTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE sync_queue (
                queue_id      TEXT PRIMARY KEY,
                target        TEXT NOT NULL DEFAULT 'csv_mirror',
                operation     TEXT NOT NULL,
                payload_json  TEXT NOT NULL,
                enqueued_at   INTEGER NOT NULL,
                attempted_at  INTEGER,
                completed_at  INTEGER,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error    TEXT
            )
        """)
        try db.execute(sql: """
            CREATE INDEX sync_pending
            ON sync_queue(target, enqueued_at)
            WHERE completed_at IS NULL
        """)
    }

    // MARK: - settings (single-row JSON blob)

    private static func createSettingsTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE settings (
                id            INTEGER PRIMARY KEY CHECK (id = 1),
                settings_json TEXT NOT NULL
            )
        """)
        // Seed the row with defaults. Domain bootstrap is intentionally empty
        // (spec §16 — no pre-seeded domains). INSERT OR IGNORE keeps the
        // migration safe to re-run defensively, even though GRDB's migrator
        // already guarantees each named migration runs once.
        try db.execute(
            sql: "INSERT OR IGNORE INTO settings (id, settings_json) VALUES (1, ?)",
            arguments: [SettingsDefaults.json]
        )
    }
}

extension Migrations {
    // MARK: - notification_recurring_rules (Track D, v2)
    //
    // One row per active recurring notification (RRULE subset). Each row is
    // the "rule of record" — NotificationScheduler.topUpHorizon re-expands
    // active rules into the next horizon on every foreground tick. Cancelled
    // rules are kept (cancelled_at IS NOT NULL) so the audit log can still
    // resolve the rule's history.

    // v3 — additive column on memory_items. NULL = visible (default).
    // Retrieval filters `archived_at IS NULL`; undo handlers flip the value.
    fileprivate static func addMemoryItemsArchivedAtColumn(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE memory_items ADD COLUMN archived_at INTEGER")
        try db.execute(sql: """
            CREATE INDEX memory_archived_at
            ON memory_items(archived_at)
            WHERE archived_at IS NOT NULL
        """)
    }

    fileprivate static func createNotificationRecurringRulesTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE notification_recurring_rules (
                rule_id               TEXT PRIMARY KEY,
                rrule                 TEXT NOT NULL,
                kind                  TEXT NOT NULL,
                domain                TEXT,
                instrument_id         TEXT,
                template_context_json TEXT NOT NULL,
                action_context_json   TEXT,
                priority              INTEGER NOT NULL DEFAULT 0,
                scope_actor           TEXT NOT NULL DEFAULT 'coordinator',
                created_at            INTEGER NOT NULL,
                cancelled_at          INTEGER
            )
        """)
        try db.execute(sql: """
            CREATE INDEX notification_recurring_active
            ON notification_recurring_rules(kind, created_at)
            WHERE cancelled_at IS NULL
        """)
    }
}

/// Default settings JSON per spec §5. Stored as a TEXT blob in `settings`.
enum SettingsDefaults {
    static let json: String = """
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
    """
}
