-- 0011: Audit log for every mutating HTTP request.
--
-- One row per POST/PUT/PATCH/DELETE through the API. Written by the
-- httpapi audit middleware AFTER the handler returns, so status_code
-- + error_code reflect what actually happened (including 4xx/5xx
-- failures — attempted-but-rejected actions are interesting too).
--
-- What's recorded:
--   - actor_*: denormalised on purpose. If a user is deleted later we
--     still want their name in the audit trail; the FK on user_id
--     stays NULLable so a true delete (rare; should be soft) doesn't
--     orphan the row.
--   - path_pattern: the matched route template (e.g. /bikes/{id}/restore),
--     NOT the concrete URL. Lets you group rows by action without
--     bucketing on every ID.
--   - target_entity / target_id: best-effort, derived from the path
--     (`/bikes/{id}` → entity='bikes', id=<value>). Lets you query
--     "show me everything that happened to bike X".
--   - error_code: the stable error code from the JSON body when the
--     response is a 4xx/5xx; empty on success.
--
-- What's deliberately NOT recorded (yet):
--   - Request body, response body, before/after diffs. PII risk +
--     storage growth. Engine-level hooks can add structured diffs
--     later in a sibling `audit_log_changes` table without disturbing
--     this one.

CREATE TABLE audit_log (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    at              TEXT    NOT NULL,          -- RFC3339 UTC
    actor_user_id   TEXT,                      -- NULL for unauthenticated mutations
    actor_role      TEXT    NOT NULL DEFAULT '',
    actor_name      TEXT    NOT NULL DEFAULT '',
    method          TEXT    NOT NULL,
    path_pattern    TEXT    NOT NULL,
    target_entity   TEXT    NOT NULL DEFAULT '',
    target_id       TEXT    NOT NULL DEFAULT '',
    status_code     INTEGER NOT NULL,
    error_code      TEXT    NOT NULL DEFAULT ''
);

CREATE INDEX audit_log_school_at_idx
    ON audit_log(school_id, at DESC);

CREATE INDEX audit_log_target_idx
    ON audit_log(school_id, target_entity, target_id, at DESC);
