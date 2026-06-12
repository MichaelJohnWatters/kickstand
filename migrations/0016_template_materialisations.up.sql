-- 0016: Materialisation history for session templates.
--
-- One row per "Generate next N weeks" pass: when it happened, who
-- triggered it, the window used, and how many sessions it created.
-- Each generated session points back via `sessions.source_materialisation_id`
-- so undo knows exactly which sessions to delete.
--
-- Undo is the load-bearing feature here. The manager hits Generate,
-- realises they used the wrong instructor, and needs to roll back
-- without surgically deleting one-by-one. We refuse the undo if any
-- of the generated sessions already has a booking (avoiding a
-- destructive cascade) — they can resolve those manually.

CREATE TABLE template_materialisations (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    at              TEXT    NOT NULL,                   -- RFC3339 UTC
    performed_by    TEXT    NOT NULL REFERENCES users(id),
    weeks           INTEGER NOT NULL CHECK (weeks > 0),
    window_from     TEXT    NOT NULL,                   -- YYYY-MM-DD
    window_to       TEXT    NOT NULL,                   -- YYYY-MM-DD
    created_count   INTEGER NOT NULL,
    undone_at       TEXT,
    undone_by       TEXT    REFERENCES users(id)
);
CREATE INDEX template_materialisations_school_at_idx
    ON template_materialisations(school_id, at DESC);

-- Join key from a concrete session back to the pass that spawned it.
-- NULL for sessions created before this migration (or via the ad-hoc
-- calendar flow). Undo finds its rows via this column.
ALTER TABLE sessions ADD COLUMN source_materialisation_id TEXT
    REFERENCES template_materialisations(id);

CREATE INDEX sessions_source_materialisation_idx
    ON sessions(school_id, source_materialisation_id);
