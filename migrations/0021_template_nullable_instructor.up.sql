-- 0021: Make session_templates.instructor_id nullable.
--
-- Same motivation as sessions in 0020: the manager wants to scaffold
-- the weekly schedule without committing to an instructor up front.
-- The materialiser passes the null straight through to sessions, so
-- a template with no instructor produces sessions with no instructor
-- (which the calendar then surfaces as "Needs instructor").
--
-- SQLite has no ALTER COLUMN; standard rebuild-rename pattern.

PRAGMA foreign_keys=OFF;

CREATE TABLE session_templates_new (
    id                TEXT    PRIMARY KEY,
    school_id         TEXT    NOT NULL REFERENCES schools(id),
    course_type_id    TEXT    NOT NULL REFERENCES course_types(id),
    instructor_id     TEXT    REFERENCES users(id),
    location_id       TEXT    NOT NULL REFERENCES locations(id),
    weekday           INTEGER NOT NULL CHECK (weekday BETWEEN 0 AND 6),
    starts_at_time    TEXT    NOT NULL,
    duration_minutes  INTEGER NOT NULL CHECK (duration_minutes > 0),
    capacity          INTEGER NOT NULL CHECK (capacity > 0),
    starts_on         TEXT,
    ends_on           TEXT,
    notes             TEXT,
    created_at        TEXT    NOT NULL,
    created_by        TEXT    NOT NULL REFERENCES users(id)
);

INSERT INTO session_templates_new SELECT * FROM session_templates;
DROP TABLE session_templates;
ALTER TABLE session_templates_new RENAME TO session_templates;
CREATE INDEX session_templates_school_idx ON session_templates(school_id, weekday);

PRAGMA foreign_keys=ON;
