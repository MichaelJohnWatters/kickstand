-- SQLite can't DROP COLUMN before 3.35 — and even on newer SQLite we
-- avoid it here because rolling back a privacy scrub doesn't restore
-- the original PII. The marker just becomes dead weight on rollback;
-- intentional no-op.
SELECT 1;
