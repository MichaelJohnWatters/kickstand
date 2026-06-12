-- 0019: Incident review workflow.
--
-- When an incident is logged, the school is on the hook for follow-up:
-- check the bike, ring the student, notify the insurer. Right now those
-- happen offline and slip — we capture them as structured rows so the
-- "needs attention" surface can chase them.
--
-- Default checklist spawned automatically on incident create:
--   - mechanical_check    — bike inspected, sign-off from instructor or mechanic
--   - student_welfare     — call/text the student, confirm they're OK
--   - insurance_notify    — when severity warrants, notify the insurer
--
-- Schools can deactivate / customise later if needed. For now, the
-- engine spawns the three on every new incident and lets the manager
-- tick them off as they're done.

CREATE TABLE incident_followups (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    incident_id     TEXT    NOT NULL REFERENCES incidents(id),
    kind            TEXT    NOT NULL,
        -- 'mechanical_check' | 'student_welfare' | 'insurance_notify' | 'other'
    description     TEXT    NOT NULL DEFAULT '',
    owner_user_id   TEXT    REFERENCES users(id),
    due_on          TEXT,                       -- YYYY-MM-DD, optional
    done_at         TEXT,                       -- RFC3339 when marked done
    done_by         TEXT    REFERENCES users(id),
    notes           TEXT    NOT NULL DEFAULT '',
    created_at      TEXT    NOT NULL,
    created_by      TEXT    NOT NULL REFERENCES users(id)
);

CREATE INDEX incident_followups_incident_idx
    ON incident_followups(school_id, incident_id, created_at);

CREATE INDEX incident_followups_open_idx
    ON incident_followups(school_id, done_at, due_on);
