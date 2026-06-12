DROP INDEX IF EXISTS sessions_template_occurrence_uidx;
ALTER TABLE sessions DROP COLUMN source_template_id;
DROP INDEX IF EXISTS session_templates_school_idx;
DROP TABLE IF EXISTS session_templates;
