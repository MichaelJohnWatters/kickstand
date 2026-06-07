-- SQLite doesn't support DROP COLUMN before 3.35. modernc.org/sqlite ships
-- a recent enough version, so this is fine; but most production rollbacks
-- would just leave the column in place.
ALTER TABLE student_profiles DROP COLUMN signup_note;
