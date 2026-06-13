-- 0029: Optional lat/lng on locations.
--
-- The risks doc on `gps-and-analytics-plan.md` flagged that v1 of the
-- GPS write endpoint only validates -90/90, -180/180 — meaning bad
-- client data could silently "park" a bike off the coast of Iceland.
-- With these columns we can run a proximity check: reject any fix
-- more than ~200km from every one of the school's sites.
--
-- Nullable because schools enable the live map progressively. A
-- location without coords just doesn't participate in the proximity
-- ring — the engine treats it as "we don't know where this site is."
-- When zero of the school's locations carry coords the check is
-- skipped entirely (graceful degrade, same outcome as today).
--
-- WGS-84 decimal degrees, same as the bike fix columns.

ALTER TABLE locations ADD COLUMN lat REAL;
ALTER TABLE locations ADD COLUMN lng REAL;
