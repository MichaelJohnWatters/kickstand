-- 0024: Track when a pending sign-up was approved.
--
-- The Approved tab on the Sign-ups screen shows recently-approved
-- applicants for a few days so the manager can still grab the phone
-- number to call the student. We need an absolute approval time to
-- sort by — users.created_at is the signup time, not the approval
-- time. Existing active students get NULL (we don't backfill from
-- the audit log) and will simply not appear in the Approved tab,
-- which is the correct behaviour.

ALTER TABLE users ADD COLUMN approved_at TEXT;
