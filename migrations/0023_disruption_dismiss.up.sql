-- 0023: Add 'dismissed' to disruption_affected_bookings.resolution.
--
-- "Dismissed" is the post-session cleanup state: the manager never
-- resolved the disruption row, the session has come and gone, and we
-- just want to drop it off the queue. It's NOT the same as
-- cancel_with_approval — for cancel_with_approval the school is
-- pre-emptively giving up on a future session (and the engine voids
-- the auto-charge so the student isn't billed for what didn't
-- happen). For dismiss, the session already ran whichever way it ran
-- (maybe the student attended on a borrowed bike, maybe they didn't
-- show), so the booking + charge stay as-is and the student isn't
-- pinged with a "your booking was cancelled" notification after the
-- fact.
--
-- SQLite can't add CHECK constraints in-place, so we rebuild the
-- table. Old data preserved verbatim.

PRAGMA foreign_keys = OFF;

CREATE TABLE disruption_affected_bookings_new (
    school_id     TEXT NOT NULL REFERENCES schools(id),
    disruption_id TEXT NOT NULL REFERENCES disruptions(id),
    booking_id    TEXT NOT NULL REFERENCES bookings(id),
    resolution    TEXT NOT NULL DEFAULT 'pending'
                       CHECK (resolution IN ('pending', 'swapped', 'cancel_with_approval', 'cancelled', 'dismissed')),
    new_bike_id   TEXT REFERENCES bikes(id),
    resolved_at   TEXT,
    PRIMARY KEY (disruption_id, booking_id)
);

INSERT INTO disruption_affected_bookings_new
    (school_id, disruption_id, booking_id, resolution, new_bike_id, resolved_at)
SELECT school_id, disruption_id, booking_id, resolution, new_bike_id, resolved_at
FROM disruption_affected_bookings;

DROP TABLE disruption_affected_bookings;
ALTER TABLE disruption_affected_bookings_new RENAME TO disruption_affected_bookings;

PRAGMA foreign_keys = ON;
