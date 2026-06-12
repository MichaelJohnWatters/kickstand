-- 0020: Nullable instructor + multi-instructor support on sessions.
--
-- Why both at once: same SQLite rewrite, same logical concept ("a
-- session can have 0..N instructors"). Splitting would mean rewriting
-- the sessions table twice.
--
-- Behaviour:
--   - `sessions.instructor_id` becomes nullable. Managers create a
--     session shell, assign instructors later.
--   - `session_instructors` is the source of truth for the full
--     assignment. is_primary marks the one shown on the calendar
--     block; co-instructors render as extras.
--   - `sessions.instructor_id` is kept as a denormalised cache of the
--     primary so the existing reads (calendar JOIN, reminders) stay
--     fast. SetInstructors keeps it in sync.
--   - Sessions with NO instructors are unbookable — the booking
--     engine returns ErrNoInstructorAssigned. The calendar block
--     shows a "Needs instructor" pill so the manager spots them.
--
-- SQLite doesn't support ALTER COLUMN. Standard table-rebuild pattern:
-- new table, copy, drop, rename, recreate indexes.

PRAGMA foreign_keys=OFF;

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
                            CHECK (status IN ('scheduled', 'completed', 'cancelled')),
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

PRAGMA foreign_keys=ON;

CREATE TABLE session_instructors (
    id            TEXT    PRIMARY KEY,
    school_id     TEXT    NOT NULL REFERENCES schools(id),
    session_id    TEXT    NOT NULL REFERENCES sessions(id),
    instructor_id TEXT    NOT NULL REFERENCES users(id),
    is_primary    INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0, 1)),
    assigned_at   TEXT    NOT NULL,
    assigned_by   TEXT    NOT NULL REFERENCES users(id),
    UNIQUE(session_id, instructor_id)
);
CREATE INDEX session_instructors_session_idx
    ON session_instructors(school_id, session_id);
CREATE INDEX session_instructors_instructor_idx
    ON session_instructors(school_id, instructor_id);

-- Backfill: every existing session has its instructor_id populated
-- (the old NOT NULL guaranteed it). Mark that one as primary.
INSERT INTO session_instructors
    (id, school_id, session_id, instructor_id, is_primary, assigned_at, assigned_by)
SELECT
    lower(hex(randomblob(16))),
    s.school_id,
    s.id,
    s.instructor_id,
    1,
    s.created_at,
    s.instructor_id
FROM sessions s
WHERE s.instructor_id IS NOT NULL;
