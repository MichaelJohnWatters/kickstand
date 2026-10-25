-- 0030: single-use tokens for password reset (and, later, email verification).
-- We store only a SHA-256 hash of the opaque token, never the token itself —
-- a DB leak then can't be used to reset anyone's password.
CREATE TABLE auth_tokens (
    token_hash  TEXT    PRIMARY KEY,                 -- sha256 hex of the opaque token
    school_id   TEXT    NOT NULL REFERENCES schools(id),
    user_id     TEXT    NOT NULL REFERENCES users(id),
    purpose     TEXT    NOT NULL CHECK (purpose IN ('password_reset', 'email_verify')),
    expires_at  TEXT    NOT NULL,
    used_at     TEXT,                                -- NULL until consumed (single-use)
    created_at  TEXT    NOT NULL
);
CREATE INDEX auth_tokens_user_idx ON auth_tokens(user_id);
