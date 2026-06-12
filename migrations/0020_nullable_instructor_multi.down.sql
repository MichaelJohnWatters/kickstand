-- Down migration is intentionally lossy: dropping the join table is
-- safe (denormalised cache lives in sessions.instructor_id) but
-- restoring NOT NULL on instructor_id would refuse any sessions that
-- were created without one between up and down. We just drop the join
-- table; existing nullable instructor_id stays nullable.
DROP INDEX IF EXISTS session_instructors_instructor_idx;
DROP INDEX IF EXISTS session_instructors_session_idx;
DROP TABLE IF EXISTS session_instructors;
