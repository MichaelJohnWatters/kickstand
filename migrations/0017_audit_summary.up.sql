-- 0017: Human summary on audit rows.
--
-- The middleware writes baseline metadata (actor, method, path, status)
-- for every mutating request — that's our coverage guarantee. Handlers
-- progressively enrich the row with a one-sentence human description
-- via `audit.Describe(ctx, …)`. The middleware reads whatever was set
-- when it writes the row.
--
-- Why a single TEXT column rather than structured details JSON: the
-- audit screen renders one line per row, so a sentence is what the
-- reader actually consumes. Anything more (diffs, before/after) is a
-- separate concern that belongs in an `audit_log_changes` table when
-- we need it; deferred until a real reporting requirement lands.
--
-- DEFAULT '' so the column is back-compatible: every existing row keeps
-- rendering via the verb-mapping fallback in the client. New handler
-- calls overwrite that default.

ALTER TABLE audit_log ADD COLUMN summary TEXT NOT NULL DEFAULT '';
