-- 0012: Compliance bookkeeping for the manager.
--
-- Adds two expiry dates the school owner is legally on the hook for:
--   - instructor accreditation (DSA / DVSA grade — Northern Ireland uses
--     the same scheme via DVA). When this lapses the instructor can't
--     teach paid lessons; we surface it as red on the compliance page.
--   - school insurance. Often annual — owners forget the renewal date,
--     get caught out, can't open the doors. One row on schools is enough
--     (one policy per tenant).
--
-- Both are nullable: existing rows mean "unknown, please record it".
-- Date format YYYY-MM-DD (consistent with MOT/tax + CBT/theory columns).

ALTER TABLE instructor_profiles ADD COLUMN accreditation_expires_on TEXT;
ALTER TABLE schools             ADD COLUMN insurance_expires_on     TEXT;
