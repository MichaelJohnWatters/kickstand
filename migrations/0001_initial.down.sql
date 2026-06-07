-- Reverse of 0001_initial.up.sql. Drop in reverse-dependency order.

DROP TABLE IF EXISTS notifications;
DROP TABLE IF EXISTS events;

DROP TABLE IF EXISTS instructor_payments;
DROP TABLE IF EXISTS instructor_earning_sources;
DROP TABLE IF EXISTS instructor_earnings;
DROP TABLE IF EXISTS instructor_pay_overrides;
DROP TABLE IF EXISTS instructor_pay_models;

DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS charges;

DROP TABLE IF EXISTS student_notes;
DROP TABLE IF EXISTS incidents;

DROP TABLE IF EXISTS external_tests;

DROP TABLE IF EXISTS disruption_affected_bookings;
DROP TABLE IF EXISTS disruptions;

DROP TABLE IF EXISTS progress_records;

DROP TABLE IF EXISTS bookings;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS instructor_time_off;
DROP TABLE IF EXISTS instructor_recurring_availability;

DROP TABLE IF EXISTS competencies;
DROP TABLE IF EXISTS course_prerequisites;
DROP TABLE IF EXISTS course_types;

DROP TABLE IF EXISTS bike_unavailability;
DROP TABLE IF EXISTS bikes;
DROP TABLE IF EXISTS travel_times;
DROP TABLE IF EXISTS locations;

DROP TABLE IF EXISTS instructor_qualifications;
DROP TABLE IF EXISTS instructor_profiles;
DROP TABLE IF EXISTS student_profiles;
DROP TABLE IF EXISTS user_sessions;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS schools;
