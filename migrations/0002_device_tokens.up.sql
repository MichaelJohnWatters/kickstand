-- Device tokens for native push (FCM). The dispatcher proper is deferred
-- until the Flutter client exists; the table needs to be in place so login
-- can register tokens and we have continuity once dispatch ships.

CREATE TABLE device_tokens (
    token        TEXT    PRIMARY KEY,                                -- FCM device token
    user_id      TEXT    NOT NULL REFERENCES users(id),
    school_id    TEXT    NOT NULL REFERENCES schools(id),
    platform     TEXT    NOT NULL CHECK (platform IN ('ios', 'android', 'web')),
    created_at   TEXT    NOT NULL,
    last_seen_at TEXT    NOT NULL
);
CREATE INDEX device_tokens_user_idx ON device_tokens(user_id);
CREATE INDEX device_tokens_school_idx ON device_tokens(school_id);
