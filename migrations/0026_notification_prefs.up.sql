-- 0026: Per-user notification preferences.
--
-- One row per (user, category) — channel toggles live as columns so a
-- single read fetches the whole row. Defaults to "all on" so users
-- who never visit the prefs screen still get every alert (the
-- safer default for a safety-relevant product).
--
-- SMS defaults to OFF because it costs money — we never want to
-- auto-enable a paid channel.
--
-- Categories must match the constants in `internal/notify` (booking /
-- disruption / payment / reminder). The CHECK is deliberately a
-- whitelist — if we add a category we update the constraint in a
-- new migration, which forces a deliberate decision about defaults.

CREATE TABLE notification_prefs (
    school_id   TEXT    NOT NULL REFERENCES schools(id),
    user_id     TEXT    NOT NULL REFERENCES users(id),
    category    TEXT    NOT NULL CHECK (category IN ('booking', 'disruption', 'payment', 'reminder')),
    in_app      INTEGER NOT NULL DEFAULT 1 CHECK (in_app IN (0, 1)),
    email       INTEGER NOT NULL DEFAULT 1 CHECK (email IN (0, 1)),
    push        INTEGER NOT NULL DEFAULT 1 CHECK (push IN (0, 1)),
    sms         INTEGER NOT NULL DEFAULT 0 CHECK (sms IN (0, 1)),
    updated_at  TEXT    NOT NULL,
    PRIMARY KEY (user_id, category)
);

CREATE INDEX notification_prefs_user_idx ON notification_prefs(school_id, user_id);
