-- 0022: Rename instructor_qualifications → instructor_accreditations
-- and give each one a per-course expires_on. Drop the global
-- accreditation_expires_on on instructor_profiles — it's superseded
-- by the per-course data.
--
-- The compliance dashboard reads the soonest-expiring per instructor
-- (or "unknown" when there isn't one on file). The instructors page
-- shows the full per-course list with a date picker per row.

ALTER TABLE instructor_qualifications RENAME TO instructor_accreditations;
ALTER TABLE instructor_accreditations ADD COLUMN expires_on TEXT;

-- Backfill: copy the global expiry into each existing accreditation
-- so the manager doesn't lose data on the rename.
UPDATE instructor_accreditations
   SET expires_on = (
       SELECT accreditation_expires_on
         FROM instructor_profiles ip
        WHERE ip.user_id = instructor_accreditations.instructor_id
          AND ip.school_id = instructor_accreditations.school_id)
 WHERE expires_on IS NULL;

ALTER TABLE instructor_profiles DROP COLUMN accreditation_expires_on;
