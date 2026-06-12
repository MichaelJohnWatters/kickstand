DROP INDEX IF EXISTS sessions_source_materialisation_idx;
ALTER TABLE sessions DROP COLUMN source_materialisation_id;
DROP INDEX IF EXISTS template_materialisations_school_at_idx;
DROP TABLE IF EXISTS template_materialisations;
