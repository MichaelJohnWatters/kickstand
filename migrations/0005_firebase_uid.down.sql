DROP INDEX IF EXISTS users_firebase_uid_idx;
ALTER TABLE users DROP COLUMN firebase_uid;
