// Package privacy is the GDPR surface — data-portability (Article
// 20 / "right of access") and right-to-erasure (Article 17).
//
// Export is read-only and returns the caller's own data as a
// structured map ready to JSON-marshal. Anonymise blanks the
// identifying columns on the users row + the role profile, leaving
// the user_id intact so FK chains to financial records and audit
// trails stay valid. It does NOT delete anything.
//
// Why soft-anonymise rather than hard-delete: bookings, charges,
// payments, instructor_earnings and audit_log all FK to users(id).
// A cascade-delete would wipe a school's books; a delete without
// cascade would fail. UK financial records carry a 6-year retention
// duty independent of the data subject's wishes. Scrubbing the
// identifying columns is the GDPR-compliant compromise — the row
// is no longer personal data, and the records that need to persist
// can.
package privacy

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// ErrNotFound is returned when the target user doesn't exist in the
// caller's school scope (or the caller's "me" reference is stale).
var ErrNotFound = errors.New("privacy: user not found")

// ErrAlreadyAnonymised is returned by Anonymise if the row is already
// scrubbed. The endpoint surfaces this as 409 so accidental re-runs
// stay idempotent on the caller side without silently doing nothing.
var ErrAlreadyAnonymised = errors.New("privacy: already anonymised")

// Export aggregates a single user's personal data into one nested
// structure. Read-only across all the tables that can carry PII or
// the subject's own actions:
//
//   - users + role profile (student or instructor)
//   - bookings + the parent sessions
//   - ledger: charges + payments
//   - notes (staff-authored notes ABOUT this user — they're the data
//     subject for those rows even though they didn't write them)
//   - incidents involving the user
//   - external test results
//   - waitlist entries
//   - notification preferences
//
// The audit_log is explicitly NOT included. It's a school's record of
// its own staff's actions — the user has no Article 20 claim over a
// log of their school's mutations.
func Export(ctx context.Context, scope *tenant.Scope, userID domain.UserID) (map[string]any, error) {
	row := scope.Conn().QueryRowContext(ctx, `
		SELECT
			u.email, u.phone, u.name, u.role, u.account_status,
			u.created_at, COALESCE(u.anonymised_at, '')
		FROM users u
		WHERE u.id = ? AND u.school_id = ?
	`, string(userID), string(scope.SchoolID()))
	var email, phone, name, role, status, createdAt, anonymisedAt string
	var phoneNullable sql.NullString
	if err := row.Scan(&email, &phoneNullable, &name, &role, &status, &createdAt, &anonymisedAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("export user: %w", err)
	}
	if phoneNullable.Valid {
		phone = phoneNullable.String
	}

	out := map[string]any{
		"exportedAt": time.Now().UTC().Format(time.RFC3339),
		"user": map[string]any{
			"id":            string(userID),
			"email":         email,
			"phone":         phone,
			"name":          name,
			"role":          role,
			"accountStatus": status,
			"createdAt":     createdAt,
			"anonymisedAt":  anonymisedAt,
		},
	}

	switch role {
	case "student":
		profile, err := exportStudentProfile(ctx, scope, userID)
		if err != nil {
			return nil, err
		}
		out["studentProfile"] = profile
	case "instructor":
		profile, err := exportInstructorProfile(ctx, scope, userID)
		if err != nil {
			return nil, err
		}
		out["instructorProfile"] = profile
	}

	if bookings, err := exportBookings(ctx, scope, userID); err == nil {
		out["bookings"] = bookings
	} else {
		return nil, err
	}
	if charges, err := exportCharges(ctx, scope, userID); err == nil {
		out["charges"] = charges
	} else {
		return nil, err
	}
	if payments, err := exportPayments(ctx, scope, userID); err == nil {
		out["payments"] = payments
	} else {
		return nil, err
	}
	if notes, err := exportNotes(ctx, scope, userID); err == nil {
		out["notes"] = notes
	} else {
		return nil, err
	}
	if incidents, err := exportIncidents(ctx, scope, userID); err == nil {
		out["incidents"] = incidents
	} else {
		return nil, err
	}
	if tests, err := exportTests(ctx, scope, userID); err == nil {
		out["externalTests"] = tests
	} else {
		return nil, err
	}
	if waitlist, err := exportWaitlist(ctx, scope, userID); err == nil {
		out["waitlist"] = waitlist
	} else {
		return nil, err
	}
	if prefs, err := exportNotificationPrefs(ctx, scope, userID); err == nil {
		out["notificationPrefs"] = prefs
	} else {
		return nil, err
	}
	return out, nil
}

func exportStudentProfile(ctx context.Context, scope *tenant.Scope, id domain.UserID) (map[string]any, error) {
	row := scope.Conn().QueryRowContext(ctx, `
		SELECT
			COALESCE(provisional_licence_no, ''),
			COALESCE(licence_category_pursued, ''),
			COALESCE(rider_date_of_birth, ''),
			COALESCE(transmission_preference, ''),
			cbt_certificate_held,
			COALESCE(cbt_variant, ''),
			COALESCE(cbt_expires_on, ''),
			COALESCE(cbt_region, ''),
			theory_passed,
			COALESCE(theory_passed_on, '')
		FROM student_profiles
		WHERE user_id = ? AND school_id = ?
	`, string(id), string(scope.SchoolID()))
	out := map[string]any{}
	var provLic, licCat, dob, trans, cbtVariant, cbtExpires, cbtRegion, theoryOn string
	var cbtHeld, theoryPassed int
	if err := row.Scan(&provLic, &licCat, &dob, &trans, &cbtHeld, &cbtVariant, &cbtExpires, &cbtRegion, &theoryPassed, &theoryOn); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return out, nil
		}
		return nil, fmt.Errorf("export student profile: %w", err)
	}
	out["provisionalLicenceNo"] = provLic
	out["licenceCategoryPursued"] = licCat
	out["riderDateOfBirth"] = dob
	out["transmissionPreference"] = trans
	out["cbtCertificateHeld"] = cbtHeld == 1
	out["cbtVariant"] = cbtVariant
	out["cbtExpiresOn"] = cbtExpires
	out["cbtRegion"] = cbtRegion
	out["theoryPassed"] = theoryPassed == 1
	out["theoryPassedOn"] = theoryOn
	return out, nil
}

func exportInstructorProfile(ctx context.Context, scope *tenant.Scope, id domain.UserID) (map[string]any, error) {
	row := scope.Conn().QueryRowContext(ctx, `
		SELECT COALESCE(home_location_id, ''), COALESCE(certifications, '')
		FROM instructor_profiles
		WHERE user_id = ? AND school_id = ?
	`, string(id), string(scope.SchoolID()))
	out := map[string]any{}
	var home, certs string
	if err := row.Scan(&home, &certs); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return out, nil
		}
		return nil, fmt.Errorf("export instructor profile: %w", err)
	}
	out["homeLocationId"] = home
	out["certifications"] = certs
	return out, nil
}

func exportBookings(ctx context.Context, scope *tenant.Scope, id domain.UserID) ([]map[string]any, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT b.id, b.status, b.created_at, COALESCE(b.cancelled_at, ''),
		       COALESCE(b.cancellation_reason, ''),
		       s.id, s.starts_at, s.ends_at,
		       COALESCE(ct.code, ''), COALESCE(ct.name, '')
		FROM bookings b
		JOIN sessions s ON s.id = b.session_id AND s.school_id = b.school_id
		LEFT JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		WHERE b.student_id = ? AND b.school_id = ?
		ORDER BY s.starts_at DESC
	`, string(id), string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("export bookings: %w", err)
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var bid, status, createdAt, cancelledAt, reason, sid, startsAt, endsAt, code, name string
		if err := rows.Scan(&bid, &status, &createdAt, &cancelledAt, &reason,
			&sid, &startsAt, &endsAt, &code, &name); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"id":                 bid,
			"status":             status,
			"createdAt":          createdAt,
			"cancelledAt":        cancelledAt,
			"cancellationReason": reason,
			"session": map[string]any{
				"id":         sid,
				"startsAt":   startsAt,
				"endsAt":     endsAt,
				"courseCode": code,
				"courseName": name,
			},
		})
	}
	return out, rows.Err()
}

func exportCharges(ctx context.Context, scope *tenant.Scope, id domain.UserID) ([]map[string]any, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, amount_pence, COALESCE(description, ''), created_at,
		       COALESCE(voided_at, ''), COALESCE(void_reason, '')
		FROM charges
		WHERE student_id = ? AND school_id = ?
		ORDER BY created_at DESC
	`, string(id), string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("export charges: %w", err)
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var cid, desc, createdAt, voidedAt, voidedReason string
		var amt int
		if err := rows.Scan(&cid, &amt, &desc, &createdAt, &voidedAt, &voidedReason); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"id":           cid,
			"amountPence":  amt,
			"description":  desc,
			"createdAt":    createdAt,
			"voidedAt":     voidedAt,
			"voidedReason": voidedReason,
		})
	}
	return out, rows.Err()
}

func exportPayments(ctx context.Context, scope *tenant.Scope, id domain.UserID) ([]map[string]any, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, amount_pence, COALESCE(method, ''), COALESCE(notes, ''),
		       received_at, COALESCE(voided_at, '')
		FROM payments
		WHERE student_id = ? AND school_id = ?
		ORDER BY received_at DESC
	`, string(id), string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("export payments: %w", err)
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var pid, method, notes, receivedAt, voidedAt string
		var amt int
		if err := rows.Scan(&pid, &amt, &method, &notes, &receivedAt, &voidedAt); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"id":          pid,
			"amountPence": amt,
			"method":      method,
			"notes":       notes,
			"receivedAt":  receivedAt,
			"voidedAt":    voidedAt,
		})
	}
	return out, rows.Err()
}

func exportNotes(ctx context.Context, scope *tenant.Scope, id domain.UserID) ([]map[string]any, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, COALESCE(kind, ''), COALESCE(body, ''),
		       created_at, COALESCE(created_by, '')
		FROM student_notes
		WHERE student_id = ? AND school_id = ?
		ORDER BY created_at DESC
	`, string(id), string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("export notes: %w", err)
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var nid, kind, body, createdAt, createdBy string
		if err := rows.Scan(&nid, &kind, &body, &createdAt, &createdBy); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"id":        nid,
			"kind":      kind,
			"body":      body,
			"createdAt": createdAt,
			"createdBy": createdBy,
		})
	}
	return out, rows.Err()
}

func exportIncidents(ctx context.Context, scope *tenant.Scope, id domain.UserID) ([]map[string]any, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, COALESCE(description, ''), occurred_at,
		       created_at, COALESCE(created_by, '')
		FROM incidents
		WHERE student_id = ? AND school_id = ?
		ORDER BY occurred_at DESC
	`, string(id), string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("export incidents: %w", err)
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var iid, desc, occurredAt, createdAt, createdBy string
		if err := rows.Scan(&iid, &desc, &occurredAt, &createdAt, &createdBy); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"id":          iid,
			"description": desc,
			"occurredAt":  occurredAt,
			"createdAt":   createdAt,
			"createdBy":   createdBy,
		})
	}
	return out, rows.Err()
}

func exportTests(ctx context.Context, scope *tenant.Scope, id domain.UserID) ([]map[string]any, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, COALESCE(test_type, ''), COALESCE(outcome, ''),
		       COALESCE(scheduled_at, ''), COALESCE(region, ''),
		       COALESCE(notes, ''), created_at
		FROM external_tests
		WHERE student_id = ? AND school_id = ?
		ORDER BY COALESCE(scheduled_at, '') DESC
	`, string(id), string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("export tests: %w", err)
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var tid, kind, result, scheduledAt, region, notes, createdAt string
		if err := rows.Scan(&tid, &kind, &result, &scheduledAt, &region, &notes, &createdAt); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"id":          tid,
			"testType":    kind,
			"outcome":     result,
			"scheduledAt": scheduledAt,
			"region":      region,
			"notes":       notes,
			"createdAt":   createdAt,
		})
	}
	return out, rows.Err()
}

func exportWaitlist(ctx context.Context, scope *tenant.Scope, id domain.UserID) ([]map[string]any, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, session_id, joined_at
		FROM waitlist_entries
		WHERE student_id = ? AND school_id = ?
		ORDER BY joined_at DESC
	`, string(id), string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("export waitlist: %w", err)
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var wid, sid, joinedAt string
		if err := rows.Scan(&wid, &sid, &joinedAt); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"id":        wid,
			"sessionId": sid,
			"joinedAt":  joinedAt,
		})
	}
	return out, rows.Err()
}

func exportNotificationPrefs(ctx context.Context, scope *tenant.Scope, id domain.UserID) ([]map[string]any, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT category, in_app, email, push, sms, updated_at
		FROM notification_prefs
		WHERE user_id = ? AND school_id = ?
		ORDER BY category
	`, string(id), string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("export notification prefs: %w", err)
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var cat, updatedAt string
		var inApp, email, push, sms int
		if err := rows.Scan(&cat, &inApp, &email, &push, &sms, &updatedAt); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"category":  cat,
			"inApp":     inApp == 1,
			"email":     email == 1,
			"push":      push == 1,
			"sms":       sms == 1,
			"updatedAt": updatedAt,
		})
	}
	return out, rows.Err()
}

// Anonymise blanks PII on the users row and the matching role
// profile, sets account_status to 'disabled', and stamps
// users.anonymised_at. Bookings, ledger, audit, and the rest of
// the FK fan-out are untouched.
//
// The Firebase Auth side is the caller's responsibility — the
// handler in httpapi disables the auth user separately so this
// package stays SQL-only and testable without a Firebase Emulator.
//
// Idempotent at the SQL layer: a second call returns
// ErrAlreadyAnonymised so the handler can surface a 409 rather
// than silently no-op.
func Anonymise(ctx context.Context, scope *tenant.Scope, userID domain.UserID) error {
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		var current sql.NullString
		var role string
		if err := tx.Conn().QueryRowContext(ctx, `
			SELECT anonymised_at, role
			FROM users
			WHERE id = ? AND school_id = ?
		`, string(userID), string(scope.SchoolID())).Scan(&current, &role); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("anonymise lookup: %w", err)
		}
		if current.Valid && current.String != "" {
			return ErrAlreadyAnonymised
		}
		now := time.Now().UTC().Format(time.RFC3339)
		// Placeholder email keeps the UNIQUE constraint happy while
		// no longer being personal data. Same shape (".local" TLD)
		// every time, so a future audit can grep for them.
		placeholder := fmt.Sprintf("anon-%s@anon.local", string(userID))
		if _, err := tx.Conn().ExecContext(ctx, `
			UPDATE users
			SET email = ?, phone = NULL, name = '(Anonymised)',
			    account_status = 'disabled', anonymised_at = ?
			WHERE id = ? AND school_id = ?
		`, placeholder, now, string(userID), string(scope.SchoolID())); err != nil {
			return fmt.Errorf("anonymise users: %w", err)
		}
		switch role {
		case "student":
			if _, err := tx.Conn().ExecContext(ctx, `
				UPDATE student_profiles
				SET provisional_licence_no = NULL,
				    rider_date_of_birth = NULL
				WHERE user_id = ? AND school_id = ?
			`, string(userID), string(scope.SchoolID())); err != nil {
				return fmt.Errorf("anonymise student profile: %w", err)
			}
		case "instructor":
			if _, err := tx.Conn().ExecContext(ctx, `
				UPDATE instructor_profiles
				SET certifications = NULL
				WHERE user_id = ? AND school_id = ?
			`, string(userID), string(scope.SchoolID())); err != nil {
				return fmt.Errorf("anonymise instructor profile: %w", err)
			}
		}
		return nil
	})
}
