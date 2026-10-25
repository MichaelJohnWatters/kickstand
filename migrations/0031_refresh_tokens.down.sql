-- Revert to the narrower CHECK. Any 'refresh' rows are dropped since they would
-- not satisfy the old constraint.
CREATE TABLE auth_tokens_old (
    token_hash  TEXT    PRIMARY KEY,
    school_id   TEXT    NOT NULL REFERENCES schools(id),
    user_id     TEXT    NOT NULL REFERENCES users(id),
    purpose     TEXT    NOT NULL CHECK (purpose IN ('password_reset', 'email_verify')),
    expires_at  TEXT    NOT NULL,
    used_at     TEXT,
    created_at  TEXT    NOT NULL
);
INSERT INTO auth_tokens_old
    SELECT token_hash, school_id, user_id, purpose, expires_at, used_at, created_at
    FROM auth_tokens WHERE purpose IN ('password_reset', 'email_verify');
DROP TABLE auth_tokens;
ALTER TABLE auth_tokens_old RENAME TO auth_tokens;
CREATE INDEX auth_tokens_user_idx ON auth_tokens(user_id);
