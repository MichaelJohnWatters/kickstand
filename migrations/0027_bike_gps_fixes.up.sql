-- 0027: Per-bike GPS fix history.
--
-- The `bikes` row already carries the LATEST fix (last_known_lat /
-- last_known_lng / last_known_at) so the live map renders in one
-- read without a join. This table records every prior fix so the
-- admin "Live map" can draw a breadcrumb trail when a marker is
-- tapped.
--
-- Schools without trackers never write here — the table just stays
-- empty. The scheduling/logistics engine still does not read GPS
-- (plan §7); this is presentation-only.
--
-- One row per ping. We keep the school_id denormalised on the row
-- (cheap, and matches every other multi-tenant table here) so
-- queries can stay scoped without joining through bikes.

CREATE TABLE bike_gps_fixes (
    id         TEXT    NOT NULL PRIMARY KEY,
    school_id  TEXT    NOT NULL REFERENCES schools(id),
    bike_id    TEXT    NOT NULL REFERENCES bikes(id),
    at         TEXT    NOT NULL, -- RFC3339 UTC
    lat        REAL    NOT NULL,
    lng        REAL    NOT NULL
);

-- The history view query is always (bike, at DESC LIMIT N), so a
-- compound index by bike + at handles it without sorting.
CREATE INDEX bike_gps_fixes_bike_at_idx
    ON bike_gps_fixes(school_id, bike_id, at DESC);
