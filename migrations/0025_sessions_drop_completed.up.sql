-- 0025: Drop 'completed' from sessions.status.
--
-- Reality check: no engine code path writes 'completed' for a session,
-- and no engine query reads it. The only legitimate transition is
-- scheduled → cancelled (cancel_session). "Past" sessions are
-- identified by `now > ends_at`, not by a status flip — and that's how
-- prod already behaves.
--
-- The seed used to write 'completed' on past sessions for cosmetic
-- reasons, but it was decoration not data. We've cleaned that up too;
-- this migration normalises any leftover rows so the CHECK can be
-- tightened.
--
-- SQLite can't ALTER CHECK in-place, so rebuild the table.

PRAGMA foreign_keys = OFF;

-- Normalise any pre-existing 'completed' sessions back to 'scheduled'.
-- The data is identical for every read path that cares.
UPDATE sessions SET status = 'scheduled' WHERE status = 'completed';

CREATE TABLE sessions_new (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    course_type_id  TEXT    NOT NULL REFERENCES course_types(id),
    instructor_id   TEXT    REFERENCES users(id),
    location_id     TEXT    NOT NULL REFERENCES locations(id),
    starts_at       TEXT    NOT NULL,
    ends_at         TEXT    NOT NULL,
    capacity        INTEGER NOT NULL CHECK (capacity > 0),
    status          TEXT    NOT NULL DEFAULT 'scheduled'
                            CHECK (status IN ('scheduled', 'cancelled')),
    notes           TEXT,
    created_at      TEXT    NOT NULL,
    source_template_id TEXT REFERENCES session_templates(id),
    source_materialisation_id TEXT REFERENCES template_materialisations(id)
);

INSERT INTO sessions_new
    (id, school_id, course_type_id, instructor_id, location_id,
     starts_at, ends_at, capacity, status, notes, created_at,
     source_template_id, source_materialisation_id)
SELECT id, school_id, course_type_id, instructor_id, location_id,
       starts_at, ends_at, capacity, status, notes, created_at,
       source_template_id, source_materialisation_id
FROM sessions;

DROP TABLE sessions;
ALTER TABLE sessions_new RENAME TO sessions;

CREATE INDEX sessions_school_when_idx ON sessions(school_id, starts_at);
CREATE INDEX sessions_school_instructor_when_idx ON sessions(school_id, instructor_id, starts_at);
CREATE UNIQUE INDEX sessions_template_occurrence_uidx
    ON sessions(school_id, source_template_id, starts_at);
CREATE INDEX sessions_source_materialisation_idx
    ON sessions(school_id, source_materialisation_id);

PRAGMA foreign_keys = ON;
