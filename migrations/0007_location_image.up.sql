-- 0007: Inline header image for locations.
--
-- ~300×120 JPEG stored as a BLOB (typically 8–15 KB per row). The
-- admin locations card uses it as the card header in place of the
-- striped placeholder; other consumers (student booking detail,
-- instructor session view) can render the same byte stream.
--
-- Kept inline rather than going through the filestore because:
--   - Locations are a tiny set per tenant (~3-10 rows).
--   - Every list view wants the image, so a separate fetch per row
--     would be silly. One JSON payload carries everything.

ALTER TABLE locations ADD COLUMN image BLOB;
