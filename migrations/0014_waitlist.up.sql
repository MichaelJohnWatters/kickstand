-- 0014: Waitlist for full sessions.
--
-- A student hits a capacity_full error trying to book → they can opt in
-- to the session's waitlist instead. When a booked student cancels, the
-- booking engine consumes the head of the queue and books them
-- automatically (best-effort: same constraint engine, same advisories,
-- same auto-charge).
--
-- Schema notes:
--   - Position is implicit via joined_at ASC. We don't store an integer
--     position column to avoid expensive renumbering on leave/promotion;
--     ORDER BY joined_at, rowid is plenty for school-scale data.
--   - One row per (session, student). The UNIQUE constraint prevents
--     someone joining twice; the student leaves via DELETE then can
--     rejoin.
--   - promoted_at + promoted_booking_id record the outcome when the
--     queue head was consumed by an auto-promotion. Kept for audit /
--     UX ("you were promoted to a booking on 2026-06-10").

CREATE TABLE waitlist_entries (
    id                    TEXT    PRIMARY KEY,
    school_id             TEXT    NOT NULL REFERENCES schools(id),
    session_id            TEXT    NOT NULL REFERENCES sessions(id),
    student_id            TEXT    NOT NULL REFERENCES users(id),
    joined_at             TEXT    NOT NULL,
    promoted_at           TEXT,
    promoted_booking_id   TEXT    REFERENCES bookings(id),
    UNIQUE(session_id, student_id)
);

CREATE INDEX waitlist_session_idx
    ON waitlist_entries(school_id, session_id, joined_at);
CREATE INDEX waitlist_student_idx
    ON waitlist_entries(school_id, student_id, joined_at);
