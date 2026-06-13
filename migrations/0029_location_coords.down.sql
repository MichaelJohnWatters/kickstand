-- SQLite < 3.35 can't DROP COLUMN. Even on newer SQLite we keep the
-- columns on rollback — they're nullable and harmless.
SELECT 1;
