-- Lossy reverse: any rows currently at 'dismissed' get coerced to
-- 'cancel_with_approval' (the closest historical state) so the
-- restored CHECK constraint accepts them.

PRAGMA foreign_keys = OFF;

CREATE TABLE disruption_affected_bookings_old (
    school_id     TEXT NOT NULL REFERENCES schools(id),
    disruption_id TEXT NOT NULL REFERENCES disruptions(id),
    booking_id    TEXT NOT NULL REFERENCES bookings(id),
    resolution    TEXT NOT NULL DEFAULT 'pending'
                       CHECK (resolution IN ('pending', 'swapped', 'cancel_with_approval', 'cancelled')),
    new_bike_id   TEXT REFERENCES bikes(id),
    resolved_at   TEXT,
    PRIMARY KEY (disruption_id, booking_id)
);

INSERT INTO disruption_affected_bookings_old
    (school_id, disruption_id, booking_id, resolution, new_bike_id, resolved_at)
SELECT school_id, disruption_id, booking_id,
       CASE WHEN resolution = 'dismissed' THEN 'cancel_with_approval' ELSE resolution END,
       new_bike_id, resolved_at
FROM disruption_affected_bookings;

DROP TABLE disruption_affected_bookings;
ALTER TABLE disruption_affected_bookings_old RENAME TO disruption_affected_bookings;

PRAGMA foreign_keys = ON;
