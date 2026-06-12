-- Lossy reverse: re-add the global column (NULL for existing rows)
-- and rename back. Per-course expiries are dropped.
ALTER TABLE instructor_profiles ADD COLUMN accreditation_expires_on TEXT;
ALTER TABLE instructor_accreditations DROP COLUMN expires_on;
ALTER TABLE instructor_accreditations RENAME TO instructor_qualifications;
