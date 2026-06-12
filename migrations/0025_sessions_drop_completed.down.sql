-- Restore 'completed' to the CHECK list. Doesn't restore any data
-- (we don't know which rows used to be 'completed').

PRAGMA foreign_keys = OFF;

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
