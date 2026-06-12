-- 0018: School-wide closures (bank holidays, snow days, instructor sickness).
--
-- A closure spans `from_date` through `to_date` inclusive. Single-day
-- closures store the same value in both columns — simpler reads than
-- a separate "all_day" flag for what's essentially calendar bookkeeping.
--
-- Behaviour hooked in:
--   - Session creation refuses on closed dates.
--   - Template materialiser skips closed dates.
--   - Existing sessions on a newly-created closure are flagged on the
--     closure row (count surfaced in the UI) but NOT auto-cancelled —
--     the manager decides per-session via bulk cancel.
--
-- Indexed for the "is this date closed?" point-query that runs on
-- every session create + every template materialise day.

CREATE TABLE school_closures (
    id           TEXT PRIMARY KEY,
    school_id    TEXT NOT NULL REFERENCES schools(id),
    from_date    TEXT NOT NULL,                  -- YYYY-MM-DD
    to_date      TEXT NOT NULL,                  -- YYYY-MM-DD (≥ from_date)
    label        TEXT NOT NULL,                  -- "Christmas Day", "Snow closure"
    reason       TEXT NOT NULL DEFAULT '',       -- optional longer note
    created_at   TEXT NOT NULL,
    created_by   TEXT NOT NULL REFERENCES users(id),
    CHECK (from_date <= to_date)
);

CREATE INDEX school_closures_school_range_idx
    ON school_closures(school_id, from_date, to_date);
