DROP INDEX IF EXISTS bike_mileage_log_bike_idx;
DROP TABLE IF EXISTS bike_mileage_log;
ALTER TABLE bikes DROP COLUMN current_mileage_miles;
ALTER TABLE bikes DROP COLUMN tax_expires_on;
ALTER TABLE bikes DROP COLUMN mot_expires_on;
