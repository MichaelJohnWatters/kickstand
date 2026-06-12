-- 0013: Recurring session schedule templates.
--
-- The manager defines a recurrence ("every Saturday at 09:00, CBT-125 at
-- Belfast with Dave, capacity 4, until end of year") and the engine
-- materialises concrete `sessions` rows from it. Templates themselves
-- never appear in calendar reads — they're a generator, not a display
-- type. Sessions remain the source of truth for what's actually bookable.
--
-- Design choices:
--   - Weekday-keyed recurrence only (no "first Monday of the month"). That
--     covers ~all training-school scheduling and avoids ical-grade
--     complexity. Add more recurrence kinds when there's a real need.
--   - Materialisation is explicit and idempotent: the engine generates
--     missing sessions in [from, to). Re-running over the same window
--     does nothing because each (template_id, occurs_on) is deduped.
--   - source_template_id on `sessions` ties a materialised row back to
--     its template — used both for dedupe and for cascading edits like
--     "delete future occurrences of this template".

CREATE TABLE session_templates (
    id                TEXT    PRIMARY KEY,
    school_id         TEXT    NOT NULL REFERENCES schools(id),
    course_type_id    TEXT    NOT NULL REFERENCES course_types(id),
    instructor_id     TEXT    NOT NULL REFERENCES users(id),
    location_id       TEXT    NOT NULL REFERENCES locations(id),
    -- 0 = Sunday … 6 = Saturday. Matches Go's time.Weekday and SQLite's
    -- strftime('%w'). The materialiser walks days in [from, to) and
    -- generates one session per matching weekday.
    weekday           INTEGER NOT NULL CHECK (weekday BETWEEN 0 AND 6),
    -- Local start time in HH:MM (24h). The materialiser combines this
    -- with each matching date + the school's local timezone (UTC for
    -- now — Kickstand operates in NI / GB) to produce starts_at.
    starts_at_time    TEXT    NOT NULL,
    duration_minutes  INTEGER NOT NULL CHECK (duration_minutes > 0),
    capacity          INTEGER NOT NULL CHECK (capacity > 0),
    -- ISO YYYY-MM-DD; new sessions are only materialised on or after
    -- this date. NULL = "no lower bound" (materialise from today).
    starts_on         TEXT,
    -- ISO YYYY-MM-DD; sessions stop materialising on or after this
    -- date. NULL = "open-ended" — keep generating forever (or until
    -- the template is deleted).
    ends_on           TEXT,
    notes             TEXT,
    created_at        TEXT    NOT NULL,
    created_by        TEXT    NOT NULL REFERENCES users(id)
);
CREATE INDEX session_templates_school_idx ON session_templates(school_id, weekday);

-- Link concrete sessions back to the template that spawned them. NULL =
-- ad-hoc session created directly in the calendar (manual scheduling
-- pre-templates is still a valid path).
ALTER TABLE sessions ADD COLUMN source_template_id TEXT REFERENCES session_templates(id);

-- Dedupe key for materialised occurrences. SQLite treats multiple NULLs
-- in a UNIQUE index as distinct, so ad-hoc sessions
-- (source_template_id IS NULL) are still allowed to collide on starts_at;
-- only template-generated sessions are deduped.
CREATE UNIQUE INDEX sessions_template_occurrence_uidx
    ON sessions(school_id, source_template_id, starts_at);
