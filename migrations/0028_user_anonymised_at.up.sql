-- 0028: Right-to-erasure marker on users.
--
-- GDPR Article 17 (right to erasure) requires that we scrub PII on
-- request. We keep the row so foreign-key chains stay intact for
-- financial records, audit trails, and historical bookings — only the
-- *identifying* columns get blanked. This timestamp records *when*
-- the scrub happened so admins can see at a glance.
--
-- NULL = never anonymised (every existing row); non-NULL = scrubbed at
-- that UTC moment. The /admin/users/{id}/anonymise endpoint writes this
-- + blanks email/name/phone, and disables the Firebase Auth user so
-- the (now placeholder) email can never sign in again.
--
-- Why not just delete the row? FK fan-out is wide: bookings, charges,
-- payments, instructor_earnings, audit_log all reference users(id). A
-- delete would either cascade away history we must keep (financial
-- retention obligations) or fail the FK. Soft-anonymise is the
-- legally-equivalent answer that preserves the ledger.

ALTER TABLE users ADD COLUMN anonymised_at TEXT;
