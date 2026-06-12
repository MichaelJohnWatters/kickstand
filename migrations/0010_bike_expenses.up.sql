-- 0010: Per-bike maintenance log with receipts.
--
-- Sibling to the instructor `expenses` table — different domain. These
-- are school capex against an asset (parts, labour, MOT, tax, service)
-- and never go through an approval workflow. Admin/owner records them
-- with a receipt photo, full stop.
--
-- Category is a free-form TEXT rather than a FK so future surfaces can
-- add new kinds (e.g. 'insurance' once we bring that in) without a
-- migration. The Go layer constrains the set today.
--
-- Receipt pipeline mirrors instructor expenses: full image lives in the
-- filestore at `receipt_storage_key`, 50×50 thumb stored inline as a
-- BLOB for cheap list rendering.

CREATE TABLE bike_expenses (
    id                    TEXT    PRIMARY KEY,
    school_id             TEXT    NOT NULL REFERENCES schools(id),
    bike_id               TEXT    NOT NULL REFERENCES bikes(id),
    category              TEXT    NOT NULL,
    amount_pence          INTEGER NOT NULL CHECK (amount_pence > 0),
    occurred_at           TEXT    NOT NULL,                 -- ISO date YYYY-MM-DD
    vendor                TEXT,                              -- 'Belfast Honda Service'
    notes                 TEXT,
    receipt_storage_key   TEXT    NOT NULL,
    receipt_content_type  TEXT    NOT NULL,
    receipt_size_bytes    INTEGER NOT NULL CHECK (receipt_size_bytes > 0),
    receipt_thumb         BLOB,
    recorded_by           TEXT    NOT NULL REFERENCES users(id),
    recorded_at           TEXT    NOT NULL
);

CREATE INDEX bike_expenses_bike_idx
    ON bike_expenses(school_id, bike_id, occurred_at DESC);
