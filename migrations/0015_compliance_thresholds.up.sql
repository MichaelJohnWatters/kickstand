-- 0015: Per-school warn/urgent windows for the compliance dashboard.
--
-- Mirrors the existing MOT/tax knobs added in 0008. Pre-fill with the
-- annual-cycle defaults the compliance package was hardcoding:
--   - accreditation: 90 days warn, 30 days urgent
--   - insurance:     60 days warn, 14 days urgent

ALTER TABLE schools ADD COLUMN accreditation_warn_days   INTEGER NOT NULL DEFAULT 90;
ALTER TABLE schools ADD COLUMN accreditation_urgent_days INTEGER NOT NULL DEFAULT 30;
ALTER TABLE schools ADD COLUMN insurance_warn_days       INTEGER NOT NULL DEFAULT 60;
ALTER TABLE schools ADD COLUMN insurance_urgent_days     INTEGER NOT NULL DEFAULT 14;
