-- 0031: allow 'refresh' tokens in auth_tokens. Refresh tokens are long-lived
-- session tokens that /auth/refresh rotates (single-use, like reset tokens) to
-- mint fresh short-lived access tokens. SQLite can't widen a CHECK in place, so
-- rebuild the table; the migration runner disables FK enforcement for this.
CREATE TABLE auth_tokens_new (
    token_hash  TEXT    PRIMARY KEY,
    school_id   TEXT    NOT NULL REFERENCES schools(id),
    user_id     TEXT    NOT NULL REFERENCES users(id),
    purpose     TEXT    NOT NULL CHECK (purpose IN ('password_reset', 'email_verify', 'refresh')),
    expires_at  TEXT    NOT NULL,
    used_at     TEXT,
    created_at  TEXT    NOT NULL
);
INSERT INTO auth_tokens_new
    SELECT token_hash, school_id, user_id, purpose, expires_at, used_at, created_at FROM auth_tokens;
DROP TABLE auth_tokens;
ALTER TABLE auth_tokens_new RENAME TO auth_tokens;
CREATE INDEX auth_tokens_user_idx ON auth_tokens(user_id);
