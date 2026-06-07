-- Optional free-text note a student leaves at signup ("Wants CBT asap —
-- turns 17 next week", etc.). Surfaced on the manager's pending-signups
-- queue so they have context before approving / phoning.
ALTER TABLE student_profiles ADD COLUMN signup_note TEXT;
