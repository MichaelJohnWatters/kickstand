-- Kickstand initial schema (v1).
--
-- Conventions:
--   * Every tenant-scoped table carries school_id NOT NULL. App code MUST filter by it.
--   * Primary keys are TEXT (app-generated IDs). Portable to Postgres without renumbering.
--   * Timestamps are TEXT in ISO 8601 (YYYY-MM-DDTHH:MM:SSZ). Lexicographic sort is correct.
--   * Money is INTEGER pence. Never floats.
--   * Booleans are INTEGER 0/1 with CHECK constraints where it matters.
--   * Enums are TEXT with CHECK constraints. Easy to extend per region/school.
--
-- SQLite-specific: PRAGMA foreign_keys=ON must be set on every connection
-- (the migrations runner does this).

----------------------------------------------------------------
-- Tenancy & people
----------------------------------------------------------------

CREATE TABLE schools (
    id                              TEXT    PRIMARY KEY,
    name                            TEXT    NOT NULL,
    region                          TEXT    NOT NULL CHECK (region IN ('NI', 'GB')),
    test_body_label                 TEXT    NOT NULL,                  -- 'DVA' (NI) / 'DVSA' (GB)
    onboarding_mode                 TEXT    NOT NULL DEFAULT 'open'
                                            CHECK (onboarding_mode IN ('open', 'approval')),
    instructors_can_record_payments INTEGER NOT NULL DEFAULT 1 CHECK (instructors_can_record_payments IN (0, 1)),
    cancel_cutoff_hours             INTEGER NOT NULL DEFAULT 48,
    travel_buffer_minutes           INTEGER NOT NULL DEFAULT 15,
    cross_site_notice_hours         INTEGER NOT NULL DEFAULT 12,
    created_at                      TEXT    NOT NULL
);

CREATE TABLE users (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    email           TEXT    NOT NULL,
    phone           TEXT,                                              -- staff-visible only
    password_hash   TEXT    NOT NULL,
    name            TEXT    NOT NULL,
    role            TEXT    NOT NULL CHECK (role IN ('student', 'instructor', 'admin', 'owner')),
    account_status  TEXT    NOT NULL DEFAULT 'active'
                            CHECK (account_status IN ('active', 'pending_approval', 'disabled')),
    created_at      TEXT    NOT NULL,
    UNIQUE (school_id, email)
);
CREATE INDEX users_school_role_idx ON users(school_id, role);
CREATE UNIQUE INDEX users_email_global_idx ON users(email);
-- email is unique globally too (login is school-agnostic; we look the user up then route).

CREATE TABLE user_sessions (
    token       TEXT    PRIMARY KEY,
    user_id     TEXT    NOT NULL REFERENCES users(id),
    created_at  TEXT    NOT NULL,
    expires_at  TEXT    NOT NULL,
    revoked_at  TEXT
);
CREATE INDEX user_sessions_user_idx ON user_sessions(user_id);

CREATE TABLE student_profiles (
    user_id                     TEXT    PRIMARY KEY REFERENCES users(id),
    school_id                   TEXT    NOT NULL REFERENCES schools(id),
    provisional_licence_no      TEXT,
    licence_category_pursued    TEXT    CHECK (licence_category_pursued IN ('AM', 'A1', 'A2', 'A')),
    rider_date_of_birth         TEXT,
    transmission_preference     TEXT    CHECK (transmission_preference IN ('manual', 'auto')),
    cbt_certificate_held        INTEGER NOT NULL DEFAULT 0 CHECK (cbt_certificate_held IN (0, 1)),
    cbt_variant                 TEXT,                                  -- e.g. 'CBT-125' / 'CBT-500-650'
    cbt_expires_on              TEXT,                                  -- date YYYY-MM-DD
    cbt_region                  TEXT    CHECK (cbt_region IN ('NI', 'GB')),
    theory_passed               INTEGER NOT NULL DEFAULT 0 CHECK (theory_passed IN (0, 1)),
    theory_passed_on            TEXT
);

CREATE TABLE instructor_profiles (
    user_id             TEXT    PRIMARY KEY REFERENCES users(id),
    school_id           TEXT    NOT NULL REFERENCES schools(id),
    home_location_id    TEXT    REFERENCES locations(id),
    certifications      TEXT                                            -- free-text / JSON list
);

CREATE TABLE instructor_qualifications (
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    instructor_id   TEXT    NOT NULL REFERENCES users(id),
    course_type_id  TEXT    NOT NULL REFERENCES course_types(id),
    PRIMARY KEY (school_id, instructor_id, course_type_id)
);

----------------------------------------------------------------
-- Resources
----------------------------------------------------------------

CREATE TABLE locations (
    id          TEXT    PRIMARY KEY,
    school_id   TEXT    NOT NULL REFERENCES schools(id),
    name        TEXT    NOT NULL,
    address     TEXT,
    created_at  TEXT    NOT NULL
);
CREATE INDEX locations_school_idx ON locations(school_id);

CREATE TABLE travel_times (
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    from_location_id TEXT   NOT NULL REFERENCES locations(id),
    to_location_id  TEXT    NOT NULL REFERENCES locations(id),
    minutes         INTEGER NOT NULL,
    PRIMARY KEY (school_id, from_location_id, to_location_id),
    CHECK (from_location_id <> to_location_id)
);

CREATE TABLE bikes (
    id                   TEXT    PRIMARY KEY,
    school_id            TEXT    NOT NULL REFERENCES schools(id),
    nickname             TEXT,                                          -- 'Red Honda' etc
    make                 TEXT,
    model                TEXT,
    registration         TEXT,
    category             TEXT    NOT NULL CHECK (category IN ('A1', 'A2', 'A')),
    transmission         TEXT    NOT NULL CHECK (transmission IN ('manual', 'auto')),
    engine_cc            INTEGER,
    status               TEXT    NOT NULL DEFAULT 'ready'
                                 CHECK (status IN ('ready', 'offline', 'in_use')),
    home_location_id     TEXT    NOT NULL REFERENCES locations(id),
    current_location_id  TEXT    NOT NULL REFERENCES locations(id),
    last_known_lat       REAL,
    last_known_lng       REAL,
    last_known_at        TEXT,
    created_at           TEXT    NOT NULL
);
CREATE INDEX bikes_school_status_idx ON bikes(school_id, status);
CREATE INDEX bikes_school_cat_trans_idx ON bikes(school_id, category, transmission);
CREATE INDEX bikes_school_current_loc_idx ON bikes(school_id, current_location_id);

CREATE TABLE bike_unavailability (
    id          TEXT    PRIMARY KEY,
    school_id   TEXT    NOT NULL REFERENCES schools(id),
    bike_id     TEXT    NOT NULL REFERENCES bikes(id),
    reason      TEXT    NOT NULL CHECK (reason IN ('mechanic', 'damaged', 'broken', 'off_road', 'other')),
    starts_at   TEXT    NOT NULL,
    ends_at     TEXT    NOT NULL,                                       -- far-future for "indefinite"
    notes       TEXT,
    created_at  TEXT    NOT NULL,
    created_by  TEXT    NOT NULL REFERENCES users(id)
);
CREATE INDEX bike_unav_bike_window_idx ON bike_unavailability(school_id, bike_id, starts_at, ends_at);

----------------------------------------------------------------
-- Course catalogue
----------------------------------------------------------------

CREATE TABLE course_types (
    id                     TEXT    PRIMARY KEY,
    school_id              TEXT    NOT NULL REFERENCES schools(id),
    code                   TEXT    NOT NULL,                            -- 'CBT-125', 'PRACTICAL', 'TEST-PRACTICAL'
    name                   TEXT    NOT NULL,
    region                 TEXT    NOT NULL CHECK (region IN ('NI', 'GB')),
    required_bike_category TEXT    CHECK (required_bike_category IN ('A1', 'A2', 'A')),
    duration_minutes       INTEGER NOT NULL,
    max_ratio              INTEGER NOT NULL DEFAULT 1,                  -- max student:instructor
    price_pence            INTEGER NOT NULL DEFAULT 0,
    non_teaching           INTEGER NOT NULL DEFAULT 0 CHECK (non_teaching IN (0, 1)),
    cancellation_cutoff_hours INTEGER,
    accent_colour          TEXT,
    icon                   TEXT,
    created_at             TEXT    NOT NULL,
    UNIQUE (school_id, code)
);

CREATE TABLE course_prerequisites (
    school_id       TEXT NOT NULL REFERENCES schools(id),
    course_type_id  TEXT NOT NULL REFERENCES course_types(id),
    prereq_kind     TEXT NOT NULL CHECK (prereq_kind IN ('cbt_held', 'theory_passed')),
    PRIMARY KEY (school_id, course_type_id, prereq_kind)
);
-- Advisory only — the engine surfaces these as warnings, never gates.

CREATE TABLE competencies (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    course_type_id  TEXT    NOT NULL REFERENCES course_types(id),
    label           TEXT    NOT NULL,
    sort_order      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX competencies_course_idx ON competencies(school_id, course_type_id);

----------------------------------------------------------------
-- Availability & scheduling
----------------------------------------------------------------

CREATE TABLE instructor_recurring_availability (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    instructor_id   TEXT    NOT NULL REFERENCES users(id),
    weekday         INTEGER NOT NULL CHECK (weekday BETWEEN 0 AND 6),   -- 0=Sunday
    starts_at_local TEXT    NOT NULL,                                   -- 'HH:MM'
    ends_at_local   TEXT    NOT NULL,
    location_id     TEXT    REFERENCES locations(id)
);

CREATE TABLE instructor_time_off (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    instructor_id   TEXT    NOT NULL REFERENCES users(id),
    starts_at       TEXT    NOT NULL,
    ends_at         TEXT    NOT NULL,
    reason          TEXT
);
CREATE INDEX time_off_instructor_window_idx ON instructor_time_off(school_id, instructor_id, starts_at, ends_at);

CREATE TABLE sessions (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    course_type_id  TEXT    NOT NULL REFERENCES course_types(id),
    instructor_id   TEXT    NOT NULL REFERENCES users(id),
    location_id     TEXT    NOT NULL REFERENCES locations(id),
    starts_at       TEXT    NOT NULL,
    ends_at         TEXT    NOT NULL,
    capacity        INTEGER NOT NULL CHECK (capacity > 0),
    status          TEXT    NOT NULL DEFAULT 'scheduled'
                            CHECK (status IN ('scheduled', 'completed', 'cancelled')),
    notes           TEXT,
    created_at      TEXT    NOT NULL
);
CREATE INDEX sessions_school_when_idx ON sessions(school_id, starts_at);
CREATE INDEX sessions_school_instructor_when_idx ON sessions(school_id, instructor_id, starts_at);

CREATE TABLE bookings (
    id                  TEXT    PRIMARY KEY,
    school_id           TEXT    NOT NULL REFERENCES schools(id),
    session_id          TEXT    NOT NULL REFERENCES sessions(id),
    student_id          TEXT    NOT NULL REFERENCES users(id),
    bike_id             TEXT    REFERENCES bikes(id),                   -- nullable: auto-assigned or needs reassignment
    status              TEXT    NOT NULL DEFAULT 'booked'
                                CHECK (status IN ('booked', 'completed', 'no_show', 'cancelled', 'needs_reassignment')),
    cancelled_by        TEXT    CHECK (cancelled_by IN ('student', 'school')),
    cancellation_reason TEXT,
    notes               TEXT,                                            -- per-booking instructor notes
    created_at          TEXT    NOT NULL,
    cancelled_at        TEXT
);
CREATE INDEX bookings_session_idx ON bookings(school_id, session_id);
CREATE INDEX bookings_student_idx ON bookings(school_id, student_id);
CREATE INDEX bookings_bike_idx ON bookings(school_id, bike_id);
CREATE INDEX bookings_status_idx ON bookings(school_id, status);

-- Partial unique index: a student can only have ONE non-cancelled booking
-- per session at any time. Cancelled rows are excluded so a student who
-- cancels can rebook the same session if they change their mind. The
-- booking engine relies on this index to surface ErrAlreadyBooked.
CREATE UNIQUE INDEX bookings_active_unique
    ON bookings(school_id, session_id, student_id)
    WHERE status <> 'cancelled';

----------------------------------------------------------------
-- Progress
----------------------------------------------------------------

CREATE TABLE progress_records (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    booking_id      TEXT    NOT NULL REFERENCES bookings(id),
    student_id      TEXT    NOT NULL REFERENCES users(id),
    competency_id   TEXT    NOT NULL REFERENCES competencies(id),
    status          TEXT    NOT NULL CHECK (status IN ('not_assessed', 'developing', 'competent', 'needs_work')),
    recorded_at     TEXT    NOT NULL,
    recorded_by     TEXT    NOT NULL REFERENCES users(id),
    UNIQUE (booking_id, competency_id)
);
CREATE INDEX progress_records_student_idx ON progress_records(school_id, student_id);

----------------------------------------------------------------
-- Disruptions
----------------------------------------------------------------

CREATE TABLE disruptions (
    id          TEXT    PRIMARY KEY,
    school_id   TEXT    NOT NULL REFERENCES schools(id),
    bike_id     TEXT    NOT NULL REFERENCES bikes(id),
    started_at  TEXT    NOT NULL,
    reason      TEXT    NOT NULL,
    created_by  TEXT    NOT NULL REFERENCES users(id),
    resolved_at TEXT
);
CREATE INDEX disruptions_school_started_idx ON disruptions(school_id, started_at);

CREATE TABLE disruption_affected_bookings (
    school_id     TEXT NOT NULL REFERENCES schools(id),
    disruption_id TEXT NOT NULL REFERENCES disruptions(id),
    booking_id    TEXT NOT NULL REFERENCES bookings(id),
    resolution    TEXT NOT NULL DEFAULT 'pending'
                       CHECK (resolution IN ('pending', 'swapped', 'cancel_with_approval', 'cancelled')),
    new_bike_id   TEXT REFERENCES bikes(id),
    resolved_at   TEXT,
    PRIMARY KEY (disruption_id, booking_id)
);

----------------------------------------------------------------
-- External tests (DVA / DVSA)
----------------------------------------------------------------

CREATE TABLE external_tests (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    student_id      TEXT    NOT NULL REFERENCES users(id),
    test_type       TEXT    NOT NULL,                                   -- region-specific: 'theory', 'practical', 'mod1', 'mod2'
    region          TEXT    NOT NULL CHECK (region IN ('NI', 'GB')),
    attempt_number  INTEGER NOT NULL DEFAULT 1,
    scheduled_at    TEXT,
    reference       TEXT,
    outcome         TEXT    NOT NULL DEFAULT 'booked'
                            CHECK (outcome IN ('booked', 'pass', 'fail', 'not_yet')),
    notes           TEXT,
    created_at      TEXT    NOT NULL
);
CREATE INDEX external_tests_student_idx ON external_tests(school_id, student_id);

----------------------------------------------------------------
-- Incidents & staff-only notes
----------------------------------------------------------------

CREATE TABLE incidents (
    id                  TEXT    PRIMARY KEY,
    school_id           TEXT    NOT NULL REFERENCES schools(id),
    bike_id             TEXT    REFERENCES bikes(id),
    student_id          TEXT    REFERENCES users(id),
    booking_id          TEXT    REFERENCES bookings(id),
    occurred_at         TEXT    NOT NULL,
    description         TEXT    NOT NULL,
    took_bike_offline   INTEGER NOT NULL DEFAULT 0 CHECK (took_bike_offline IN (0, 1)),
    created_at          TEXT    NOT NULL,
    created_by          TEXT    NOT NULL REFERENCES users(id)
);
CREATE INDEX incidents_school_idx ON incidents(school_id, occurred_at);
CREATE INDEX incidents_student_idx ON incidents(school_id, student_id);

CREATE TABLE student_notes (
    id          TEXT    PRIMARY KEY,
    school_id   TEXT    NOT NULL REFERENCES schools(id),
    student_id  TEXT    NOT NULL REFERENCES users(id),
    kind        TEXT    NOT NULL CHECK (kind IN ('safety_flag', 'progress_note')),
    body        TEXT    NOT NULL,
    is_active   INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    created_at  TEXT    NOT NULL,
    created_by  TEXT    NOT NULL REFERENCES users(id)
);
CREATE INDEX student_notes_student_idx ON student_notes(school_id, student_id, kind, is_active);

----------------------------------------------------------------
-- Student ledger
----------------------------------------------------------------

CREATE TABLE charges (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    student_id      TEXT    NOT NULL REFERENCES users(id),
    booking_id      TEXT    REFERENCES bookings(id),
    amount_pence    INTEGER NOT NULL,                                   -- positive = owed
    description     TEXT    NOT NULL,
    incurred_at     TEXT    NOT NULL,
    created_at      TEXT    NOT NULL,
    created_by      TEXT    NOT NULL REFERENCES users(id),
    voided_at       TEXT,
    voided_by       TEXT    REFERENCES users(id),
    void_reason     TEXT
);
CREATE INDEX charges_student_idx ON charges(school_id, student_id);

CREATE TABLE payments (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    student_id      TEXT    NOT NULL REFERENCES users(id),
    amount_pence    INTEGER NOT NULL,                                   -- positive = received
    method          TEXT    NOT NULL CHECK (method IN ('cash', 'bank_transfer', 'card_in_person', 'other')),
    received_at     TEXT    NOT NULL,
    recorded_by     TEXT    NOT NULL REFERENCES users(id),
    notes           TEXT,
    voided_at       TEXT,
    voided_by       TEXT    REFERENCES users(id),
    void_reason     TEXT
);
CREATE INDEX payments_student_idx ON payments(school_id, student_id);

----------------------------------------------------------------
-- Instructor pay (owed-tracking, NOT payroll)
----------------------------------------------------------------

CREATE TABLE instructor_pay_models (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    instructor_id   TEXT    NOT NULL REFERENCES users(id),
    pay_basis       TEXT    NOT NULL CHECK (pay_basis IN ('percentage', 'per_day', 'per_session', 'per_hour', 'per_student', 'salary')),
    rate_value      INTEGER NOT NULL,                                   -- pence for flat; basis-points (10000=100%) for percentage
    created_at      TEXT    NOT NULL,
    UNIQUE (school_id, instructor_id)
);

CREATE TABLE instructor_pay_overrides (
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    pay_model_id    TEXT    NOT NULL REFERENCES instructor_pay_models(id),
    course_type_id  TEXT    NOT NULL REFERENCES course_types(id),
    pay_basis       TEXT    NOT NULL CHECK (pay_basis IN ('percentage', 'per_day', 'per_session', 'per_hour', 'per_student', 'salary')),
    rate_value      INTEGER NOT NULL,
    PRIMARY KEY (pay_model_id, course_type_id)
);

CREATE TABLE instructor_earnings (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    instructor_id   TEXT    NOT NULL REFERENCES users(id),
    session_id      TEXT    REFERENCES sessions(id),
    amount_pence    INTEGER NOT NULL,
    basis           TEXT    NOT NULL,                                   -- snapshot of pay_basis at time of recording
    notes           TEXT,
    created_at      TEXT    NOT NULL,
    created_by      TEXT    NOT NULL REFERENCES users(id),
    voided_at       TEXT,
    voided_by       TEXT    REFERENCES users(id)
);
CREATE INDEX instructor_earnings_inst_idx ON instructor_earnings(school_id, instructor_id);

CREATE TABLE instructor_earning_sources (
    school_id   TEXT NOT NULL REFERENCES schools(id),
    earning_id  TEXT NOT NULL REFERENCES instructor_earnings(id),
    charge_id   TEXT NOT NULL REFERENCES charges(id),
    PRIMARY KEY (earning_id, charge_id)
);
-- Only populated for percentage earnings — references the source charges so
-- "how was this calculated?" is answerable.

CREATE TABLE instructor_payments (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    instructor_id   TEXT    NOT NULL REFERENCES users(id),
    amount_pence    INTEGER NOT NULL,
    method          TEXT    NOT NULL CHECK (method IN ('cash', 'bank_transfer', 'card_in_person', 'other')),
    paid_at         TEXT    NOT NULL,
    recorded_by     TEXT    NOT NULL REFERENCES users(id),
    notes           TEXT
);
CREATE INDEX instructor_payments_inst_idx ON instructor_payments(school_id, instructor_id);

----------------------------------------------------------------
-- Notifications scaffold (phase 2, but the events log is foundational)
----------------------------------------------------------------

CREATE TABLE events (
    id          TEXT    PRIMARY KEY,
    school_id   TEXT    NOT NULL REFERENCES schools(id),
    kind        TEXT    NOT NULL,                                       -- 'booking.created', 'session.tomorrow', 'bike.down', etc
    subject_id  TEXT,                                                   -- the entity the event is about
    payload     TEXT,                                                   -- JSON
    created_at  TEXT    NOT NULL
);
CREATE INDEX events_school_kind_idx ON events(school_id, kind, created_at);

CREATE TABLE notifications (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    event_id        TEXT    NOT NULL REFERENCES events(id),
    recipient_id    TEXT    NOT NULL REFERENCES users(id),
    channel         TEXT    NOT NULL CHECK (channel IN ('in_app', 'email', 'push', 'sms')),
    category        TEXT    NOT NULL,
    status          TEXT    NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'sent', 'failed', 'read')),
    sent_at         TEXT,
    read_at         TEXT,
    failure_reason  TEXT
);
CREATE INDEX notifications_recipient_idx ON notifications(school_id, recipient_id, status);
