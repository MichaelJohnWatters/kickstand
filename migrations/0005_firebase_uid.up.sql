-- Firebase Auth migration — Phase 0 foundation.
--
-- Adds the firebase_uid column used by the post-cutover middleware to
-- look up the local profile row given a verified Firebase ID token.
--
-- Nullable for two reasons:
--   1. Co-exists safely with the legacy auth path during cutover.
--   2. Withdrawn / archived users (or future provisioning flows) can
--      still own historical rows without an active Firebase identity.
--
-- The unique index is partial so multiple NULLs don't collide. SQLite
-- supports this; the equivalent Postgres DDL is identical.
ALTER TABLE users ADD COLUMN firebase_uid TEXT;
CREATE UNIQUE INDEX users_firebase_uid_idx
    ON users(firebase_uid)
    WHERE firebase_uid IS NOT NULL;
