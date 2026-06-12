-- 0009: MOT, tax, mileage and registration tracking on bikes.
--
-- The four scalar columns are the "current state" surface — what the
-- fleet card paints and what the warning helpers compute on. All
-- nullable so bikes imported without the data don't fail the migration;
-- the card renders "unknown" for the missing fields.
--
-- The bike_mileage_log table is the audit trail. Every reading lands
-- here with the user who entered it and how it was captured (manual
-- entry, off the MOT certificate, off a service invoice, etc.). The
-- current_mileage_miles column on `bikes` is the denormalised latest
-- value — kept in sync by the engine on POST /bikes/{id}/mileage.

-- (registration already exists in the 0001 baseline; not re-added here.)
ALTER TABLE bikes ADD COLUMN mot_expires_on        TEXT;   -- YYYY-MM-DD
ALTER TABLE bikes ADD COLUMN tax_expires_on        TEXT;   -- YYYY-MM-DD
ALTER TABLE bikes ADD COLUMN current_mileage_miles INTEGER;

CREATE TABLE bike_mileage_log (
    id           TEXT    PRIMARY KEY,
    school_id    TEXT    NOT NULL REFERENCES schools(id),
    bike_id      TEXT    NOT NULL REFERENCES bikes(id),
    miles        INTEGER NOT NULL CHECK (miles >= 0),
    source       TEXT    NOT NULL DEFAULT 'manual', -- manual|mot|service|incident
    recorded_by  TEXT    NOT NULL REFERENCES users(id),
    recorded_at  TEXT    NOT NULL
);

CREATE INDEX bike_mileage_log_bike_idx
    ON bike_mileage_log(school_id, bike_id, recorded_at);
