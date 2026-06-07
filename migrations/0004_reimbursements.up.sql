-- Instructor-submitted expenses (petrol, lunch, parking, tolls, …) with
-- an approval-first workflow. Receipt photos live in the file-store; only
-- a storage key + metadata sit in the DB.
--
-- Category list is per-school (`expense_categories`) so each owner curates
-- what their instructors can submit. Defaults seeded for every school.
-- Expenses reference categories by string id (kebab) rather than FK to
-- keep removing a category from the list non-destructive — existing rows
-- keep their tag.

CREATE TABLE expense_categories (
    school_id   TEXT NOT NULL REFERENCES schools(id),
    id          TEXT NOT NULL,
    label       TEXT NOT NULL,
    icon        TEXT NOT NULL,
    tone        INTEGER NOT NULL DEFAULT 277,         -- oklch hue (matches design palette)
    active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL,
    PRIMARY KEY (school_id, id)
);
CREATE INDEX expense_categories_school_active_idx ON expense_categories(school_id, active, sort_order);

CREATE TABLE expenses (
    id                    TEXT    PRIMARY KEY,
    school_id             TEXT    NOT NULL REFERENCES schools(id),
    instructor_id         TEXT    NOT NULL REFERENCES users(id),
    category_id           TEXT    NOT NULL,                  -- expense_categories.id (denormalised on remove)
    amount_pence          INTEGER NOT NULL CHECK (amount_pence > 0),
    occurred_at           TEXT    NOT NULL,                  -- when the spend happened
    where_                TEXT,                              -- forecourt / café / car park
    notes                 TEXT,                              -- instructor's context
    status                TEXT    NOT NULL DEFAULT 'pending'
                                  CHECK (status IN ('pending','approved','rejected','reimbursed','withdrawn')),
    receipt_storage_key   TEXT    NOT NULL,                  -- e.g. expenses/{id}/receipt.jpg
    receipt_content_type  TEXT    NOT NULL,
    receipt_size_bytes    INTEGER NOT NULL CHECK (receipt_size_bytes > 0),
    -- Review trail
    reviewed_by           TEXT    REFERENCES users(id),
    reviewed_at           TEXT,
    reviewer_note         TEXT,                              -- optional on approve, required on reject
    -- Reimbursement trail
    paid_at               TEXT,
    paid_method           TEXT,                              -- 'bank' | 'cash' | 'other'
    paid_by               TEXT    REFERENCES users(id),
    -- Bookkeeping
    submitted_at          TEXT    NOT NULL,
    withdrawn_at          TEXT
);
CREATE INDEX expenses_school_status_idx     ON expenses(school_id, status);
CREATE INDEX expenses_school_instructor_idx ON expenses(school_id, instructor_id, status);
CREATE INDEX expenses_school_occurred_idx   ON expenses(school_id, occurred_at);
