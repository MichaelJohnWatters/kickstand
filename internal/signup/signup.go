// Package signup implements student self-signup + the manager approval queue.
//
// Per plan §3 ("Student onboarding"):
//
//   - Students self-sign-up via Firebase Auth (Flutter calls
//     createUserWithEmailAndPassword), then POST their profile body
//     to /auth/firebase-signup with the resulting JWT.
//   - The per-school setting `onboarding_mode` decides what happens next:
//       * 'open'     → account_status = 'active', can book immediately
//       * 'approval' → account_status = 'pending_approval', manager reviews
//   - Pending users CAN log in (browse-but-not-book — booking engine gates).
//   - The manager has the phone number to ring before approving.
package signup

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

var (
	ErrSchoolNotFound    = errors.New("signup: school not found")
	ErrEmailAlreadyInUse = errors.New("signup: email already in use")
	ErrInvalidEmail      = errors.New("signup: invalid email")
	ErrMissingField      = errors.New("signup: a required field is missing")
	ErrNotPending        = errors.New("signup: user is not in pending_approval state")
	ErrPendingNotFound   = errors.New("signup: pending user not found in this school")
)

// PublicSchool is the minimal info the signup form needs.
type PublicSchool struct {
	ID     domain.SchoolID
	Name   string
	Region domain.Region
}

// ListSchools is the only data-read function in this package that's public
// (no auth). The HTTP layer mounts it without the auth middleware.
func ListSchools(ctx context.Context, d *sql.DB) ([]PublicSchool, error) {
	rows, err := d.QueryContext(ctx, `SELECT id, name, region FROM schools ORDER BY name ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PublicSchool
	for rows.Next() {
		var s PublicSchool
		if err := rows.Scan(&s.ID, &s.Name, &s.Region); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// FirebaseSignupRequest is the payload from POST /auth/firebase-signup.
// Identity (email, password) is already established with Firebase by the
// time we see this; the body just carries the profile data we own.
type FirebaseSignupRequest struct {
	FirebaseUID            string
	SchoolID               domain.SchoolID
	Name                   string
	Email                  string
	Phone                  string
	TransmissionPreference domain.Transmission
	LicenceCategoryPursued domain.LicenceCategory
	DateOfBirth            string // YYYY-MM-DD
}

// SignupWithFirebase writes the local profile row(s) for a user whose
// Firebase identity has already been verified upstream. No password
// hashing, no session token — the client's Firebase SDK already has
// its ID token. Returns the resulting Identity, including account
// status (active vs pending) based on the school's onboarding_mode.
func SignupWithFirebase(ctx context.Context, d *sql.DB, req FirebaseSignupRequest) (*auth.Identity, error) {
	return signupFirebaseAt(ctx, d, req, time.Now)
}

func signupFirebaseAt(ctx context.Context, d *sql.DB, req FirebaseSignupRequest, nowFn func() time.Time) (*auth.Identity, error) {
	if err := validateFirebaseReq(req); err != nil {
		return nil, err
	}

	var (
		schoolName     string
		onboardingMode string
	)
	err := d.QueryRowContext(ctx,
		`SELECT name, onboarding_mode FROM schools WHERE id = ?`,
		string(req.SchoolID),
	).Scan(&schoolName, &onboardingMode)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSchoolNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("lookup school: %w", err)
	}

	status := domain.AccountActive
	if onboardingMode == "approval" {
		status = domain.AccountPendingApproval
	}

	now := nowFn().UTC()
	userID := domain.UserID(domain.NewID())
	scope := tenant.NewScope(d, req.SchoolID)
	err = scope.WithTx(ctx, func(tx *tenant.Scope) error {
		// password_hash is a vestigial NOT NULL column from before the
		// Firebase migration — write empty string. Dropped by a follow-up
		// migration.
		_, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO users (id, school_id, email, phone, password_hash, name, role, account_status, created_at, firebase_uid)
			VALUES (?, ?, ?, ?, '', ?, 'student', ?, ?, ?)
		`, string(userID), string(req.SchoolID),
			strings.ToLower(strings.TrimSpace(req.Email)), req.Phone, req.Name,
			string(status), now.Format(time.RFC3339), req.FirebaseUID)
		if err != nil {
			if isUniqueViolation(err) {
				return ErrEmailAlreadyInUse
			}
			return fmt.Errorf("insert user: %w", err)
		}
		_, err = tx.Conn().ExecContext(ctx, `
			INSERT INTO student_profiles (user_id, school_id, transmission_preference,
			    licence_category_pursued, rider_date_of_birth, cbt_certificate_held, theory_passed)
			VALUES (?, ?, ?, ?, ?, 0, 0)
		`, string(userID), string(req.SchoolID),
			string(req.TransmissionPreference), string(req.LicenceCategoryPursued), req.DateOfBirth)
		return err
	})
	if err != nil {
		return nil, err
	}
	return &auth.Identity{
		UserID:        userID,
		SchoolID:      req.SchoolID,
		Role:          domain.RoleStudent,
		AccountStatus: status,
		Email:         strings.ToLower(strings.TrimSpace(req.Email)),
		Name:          req.Name,
		FirebaseUID:   req.FirebaseUID,
	}, nil
}

func validateFirebaseReq(req FirebaseSignupRequest) error {
	if req.FirebaseUID == "" {
		return ErrMissingField
	}
	if req.SchoolID == "" || strings.TrimSpace(req.Name) == "" {
		return ErrMissingField
	}
	if !looksLikeEmail(req.Email) {
		return ErrInvalidEmail
	}
	return nil
}

// PendingApplicant is one row in the manager's "pending sign-ups" queue.
//
// Also re-used by ListRejected and ListApproved — same columns, different
// account_status filter. ApprovedAt is only populated by ListApproved.
type PendingApplicant struct {
	UserID                 domain.UserID
	Name                   string
	Email                  string
	Phone                  string
	LicenceCategoryPursued domain.LicenceCategory
	DateOfBirth            string
	TransmissionPreference domain.Transmission
	SignupNote             string // optional free-text the applicant left
	SignedUpAt             time.Time
	ApprovedAt             time.Time // zero except in ListApproved results
}

func ListPending(ctx context.Context, scope *tenant.Scope) ([]PendingApplicant, error) {
	const q = `
		SELECT u.id, u.name, u.email, COALESCE(u.phone, ''),
		       COALESCE(sp.licence_category_pursued, ''),
		       COALESCE(sp.rider_date_of_birth, ''),
		       COALESCE(sp.transmission_preference, ''),
		       COALESCE(sp.signup_note, ''),
		       u.created_at
		FROM users u
		LEFT JOIN student_profiles sp ON sp.user_id = u.id AND sp.school_id = u.school_id
		WHERE u.school_id = ? AND u.role = 'student' AND u.account_status = 'pending_approval'
		ORDER BY u.created_at ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PendingApplicant
	for rows.Next() {
		var (
			p              PendingApplicant
			createdStr     string
		)
		if err := rows.Scan(&p.UserID, &p.Name, &p.Email, &p.Phone,
			&p.LicenceCategoryPursued, &p.DateOfBirth, &p.TransmissionPreference,
			&p.SignupNote, &createdStr); err != nil {
			return nil, err
		}
		t, err := time.Parse(time.RFC3339, createdStr)
		if err == nil {
			p.SignedUpAt = t.UTC()
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Approve flips a pending student to 'active'. Errors if the user is already
// active / disabled (only pending → active is allowed via this path).
//
// Also stamps users.approved_at so the Approved tab can show recently-
// approved applicants ordered by approval time. Restore clears it back
// to NULL.
func Approve(ctx context.Context, scope *tenant.Scope, userID domain.UserID) error {
	now := time.Now().UTC().Format(time.RFC3339)
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE users SET account_status = 'active', approved_at = ?
		WHERE id = ? AND school_id = ? AND account_status = 'pending_approval' AND role = 'student'
	`, now, string(userID), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return checkPendingExists(ctx, scope, userID)
	}
	return nil
}

// Reject flips a pending student to 'disabled'. The user can still log in
// (we don't hard-delete to preserve any incidental references), but a
// disabled account is blocked at auth-time.
func Reject(ctx context.Context, scope *tenant.Scope, userID domain.UserID) error {
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE users SET account_status = 'disabled'
		WHERE id = ? AND school_id = ? AND account_status = 'pending_approval' AND role = 'student'
	`, string(userID), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return checkPendingExists(ctx, scope, userID)
	}
	return nil
}

// ListApproved returns recently-approved students (last 7 days) so the
// manager can grab the phone number to call them after approval. Same
// payload shape as ListPending, plus ApprovedAt for sorting on the
// client. Ordered by approval time, newest first.
//
// The 7-day window is a UX choice, not a privacy one — older approvals
// still appear on the main Students list. The window is just to keep the
// post-approval call-back affordance focused on "I just did this".
func ListApproved(ctx context.Context, scope *tenant.Scope) ([]PendingApplicant, error) {
	cutoff := time.Now().UTC().Add(-7 * 24 * time.Hour).Format(time.RFC3339)
	const q = `
		SELECT u.id, u.name, u.email, COALESCE(u.phone, ''),
		       COALESCE(sp.licence_category_pursued, ''),
		       COALESCE(sp.rider_date_of_birth, ''),
		       COALESCE(sp.transmission_preference, ''),
		       COALESCE(sp.signup_note, ''),
		       u.created_at, u.approved_at
		FROM users u
		LEFT JOIN student_profiles sp ON sp.user_id = u.id AND sp.school_id = u.school_id
		WHERE u.school_id = ? AND u.role = 'student' AND u.account_status = 'active'
		  AND u.approved_at IS NOT NULL AND u.approved_at >= ?
		ORDER BY u.approved_at DESC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()), cutoff)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PendingApplicant
	for rows.Next() {
		var (
			p           PendingApplicant
			createdStr  string
			approvedStr string
		)
		if err := rows.Scan(&p.UserID, &p.Name, &p.Email, &p.Phone,
			&p.LicenceCategoryPursued, &p.DateOfBirth, &p.TransmissionPreference,
			&p.SignupNote, &createdStr, &approvedStr); err != nil {
			return nil, err
		}
		if t, err := time.Parse(time.RFC3339, createdStr); err == nil {
			p.SignedUpAt = t.UTC()
		}
		if t, err := time.Parse(time.RFC3339, approvedStr); err == nil {
			p.ApprovedAt = t.UTC()
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ListRejected returns disabled student accounts so the admin can
// review past rejections and (occasionally) restore the one they hit
// by accident. Only includes students with no completed bookings —
// genuinely-disabled-active-students don't belong on this list and we
// don't want to surface them in a place an admin might unwittingly
// reactivate them. Same payload shape as ListPending for code reuse.
func ListRejected(ctx context.Context, scope *tenant.Scope) ([]PendingApplicant, error) {
	const q = `
		SELECT u.id, u.name, u.email, COALESCE(u.phone, ''),
		       COALESCE(sp.licence_category_pursued, ''),
		       COALESCE(sp.rider_date_of_birth, ''),
		       COALESCE(sp.transmission_preference, ''),
		       COALESCE(sp.signup_note, ''),
		       u.created_at
		FROM users u
		LEFT JOIN student_profiles sp ON sp.user_id = u.id AND sp.school_id = u.school_id
		WHERE u.school_id = ? AND u.role = 'student' AND u.account_status = 'disabled'
		  AND NOT EXISTS (
		    SELECT 1 FROM bookings b
		    WHERE b.school_id = u.school_id AND b.student_id = u.id
		      AND b.status IN ('booked', 'completed', 'needs_reassignment')
		  )
		ORDER BY u.created_at DESC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PendingApplicant
	for rows.Next() {
		var (
			p          PendingApplicant
			createdStr string
		)
		if err := rows.Scan(&p.UserID, &p.Name, &p.Email, &p.Phone,
			&p.LicenceCategoryPursued, &p.DateOfBirth, &p.TransmissionPreference,
			&p.SignupNote, &createdStr); err != nil {
			return nil, err
		}
		if t, err := time.Parse(time.RFC3339, createdStr); err == nil {
			p.SignedUpAt = t.UTC()
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Restore flips a rejected (disabled) student back to pending_approval
// so the admin can review them again. Only catches students that were
// rejected at signup — we add the same "no booking history" guard as
// ListRejected so a long-standing disabled account doesn't accidentally
// jump back into the signup queue.
func Restore(ctx context.Context, scope *tenant.Scope, userID domain.UserID) error {
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE users SET account_status = 'pending_approval'
		WHERE id = ? AND school_id = ? AND role = 'student'
		  AND account_status = 'disabled'
		  AND NOT EXISTS (
		    SELECT 1 FROM bookings b
		    WHERE b.school_id = users.school_id AND b.student_id = users.id
		      AND b.status IN ('booked', 'completed', 'needs_reassignment')
		  )
	`, string(userID), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrPendingNotFound
	}
	return nil
}

func checkPendingExists(ctx context.Context, scope *tenant.Scope, userID domain.UserID) error {
	var status string
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT account_status FROM users WHERE id = ? AND school_id = ? AND role = 'student'`,
		string(userID), string(scope.SchoolID()),
	).Scan(&status)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrPendingNotFound
	}
	if err != nil {
		return err
	}
	if status != "pending_approval" {
		return ErrNotPending
	}
	// Shouldn't reach here, but defensive
	return ErrPendingNotFound
}

// ----- validation -----

func looksLikeEmail(s string) bool {
	return strings.Contains(s, "@") && strings.Contains(s, ".")
}

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "UNIQUE constraint failed") ||
		strings.Contains(msg, "constraint failed: UNIQUE")
}
