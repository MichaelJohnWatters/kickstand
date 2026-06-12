-- Lossy down: any templates created with a null instructor between up
-- and down will fail the NOT NULL on the reverse rebuild. We just
-- leave the nullable column in place — no destructive action needed.
SELECT 1;
