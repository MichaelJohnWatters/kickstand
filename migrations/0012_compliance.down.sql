-- SQLite supports DROP COLUMN since 3.35 (we ship modernc.org/sqlite which
-- bundles a newer version); these statements roll back the additions in
-- 0012_compliance.up.sql.

ALTER TABLE instructor_profiles DROP COLUMN accreditation_expires_on;
ALTER TABLE schools             DROP COLUMN insurance_expires_on;
