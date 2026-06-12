-- 0008: Editable warning thresholds on the school row.
--
-- Today the bike-state warnings (MOT and tax, shipping in chunk 2 of
-- fleet-features-plan.md) are computed with hard-coded windows. These
-- columns make the windows per-school configurable from the Settings
-- page. Defaults match the previously-hardcoded values so any school
-- that never visits Settings sees no behaviour change.

ALTER TABLE schools ADD COLUMN mot_warn_days   INTEGER NOT NULL DEFAULT 90;
ALTER TABLE schools ADD COLUMN mot_urgent_days INTEGER NOT NULL DEFAULT 14;
ALTER TABLE schools ADD COLUMN tax_warn_days   INTEGER NOT NULL DEFAULT 30;
ALTER TABLE schools ADD COLUMN tax_urgent_days INTEGER NOT NULL DEFAULT 7;
