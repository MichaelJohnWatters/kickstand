// Package signup implements student self-signup + the manager approval queue.
//
// Per plan §3 ("Student onboarding"):
//
//   - Students self-sign-up with name, email, phone, password, transmission
//     pref, licence category.
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
	ErrSchoolNotFound      = errors.New("signup: school not found")
	ErrEmailAlreadyInUse   = errors.New("signup: email already in use")
	ErrInvalidEmail        = errors.New("signup: invalid email")
	ErrPasswordTooShort    = errors.New("signup: password must be at least 8 characters")
	ErrMissingField        = errors.New("signup: a required field is missing")
	ErrNotPending          = errors.New("signup: user is not in pending_approval state")
	ErrPendingNotFound     = errors.New("signup: pending user not found in this school")
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

// SignupRequest is the payload from POST /auth/signup.
type SignupRequest struct {
	SchoolID               domain.SchoolID
	Name                   string
	Email                  string
	Phone                  string
	Password               string
	TransmissionPreference domain.Transmission
	LicenceCategoryPursued domain.LicenceCategory
	DateOfBirth            string // YYYY-MM-DD
}

// SignupResult mirrors the login result shape: the new user is logged in
// immediately (returns a token) and the caller's UI uses account_status to
// render the right post-signup screen (welcome vs "awaiting approval").
type SignupResult struct {
	Token     domain.UserSessionToken
	ExpiresAt time.Time
	Identity  auth.Identity
}

// Signup creates the user + student_profile + session in one transaction.
// Returns ErrEmailAlreadyInUse if the email is taken (global unique).
func Signup(ctx context.Context, d *sql.DB, req SignupRequest) (*SignupResult, error) {
	return signupAt(ctx, d, req, time.Now)
}

func signupAt(ctx context.Context, d *sql.DB, req SignupRequest, nowFn func() time.Time) (*SignupResult, error) {
	if err := validate(req); err != nil {
		return nil, err
	}

	// Look up the school to discover onboarding_mode.
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

	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		return nil, err
	}

	now := nowFn().UTC()
	userID := domain.UserID(domain.NewID())

	// All inserts + session creation in one tx so a failed step rolls
	// everything back (no half-signed-up users).
	scope := tenant.NewScope(d, req.SchoolID)
	var token string
	var expires time.Time
	err = scope.WithTx(ctx, func(tx *tenant.Scope) error {
		_, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO users (id, school_id, email, phone, password_hash, name, role, account_status, created_at)
			VALUES (?, ?, ?, ?, ?, ?, 'student', ?, ?)
		`, string(userID), string(req.SchoolID), strings.ToLower(strings.TrimSpace(req.Email)),
			req.Phone, hash, req.Name, string(status), now.Format(time.RFC3339))
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
		if err != nil {
			return fmt.Errorf("insert profile: %w", err)
		}

		token, err = auth.NewSessionToken()
		if err != nil {
			return err
		}
		expires = now.Add(auth.DefaultSessionTTL)
		_, err = tx.Conn().ExecContext(ctx, `
			INSERT INTO user_sessions (token, user_id, created_at, expires_at)
			VALUES (?, ?, ?, ?)
		`, token, string(userID), now.Format(time.RFC3339), expires.Format(time.RFC3339))
		return err
	})
	if err != nil {
		return nil, err
	}

	return &SignupResult{
		Token:     domain.UserSessionToken(token),
		ExpiresAt: expires,
		Identity: auth.Identity{
			UserID:        userID,
			SchoolID:      req.SchoolID,
			Role:          domain.RoleStudent,
			AccountStatus: status,
			Email:         strings.ToLower(strings.TrimSpace(req.Email)),
			Name:          req.Name,
		},
	}, nil
}

// PendingApplicant is one row in the manager's "pending sign-ups" queue.
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
func Approve(ctx context.Context, scope *tenant.Scope, userID domain.UserID) error {
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE users SET account_status = 'active'
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

func validate(r SignupRequest) error {
	if r.SchoolID == "" || r.Name == "" || r.Email == "" || r.Password == "" {
		return ErrMissingField
	}
	if !strings.Contains(r.Email, "@") || !strings.Contains(r.Email, ".") {
		return ErrInvalidEmail
	}
	if len(r.Password) < 8 {
		return ErrPasswordTooShort
	}
	return nil
}

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "UNIQUE constraint failed") ||
		strings.Contains(msg, "constraint failed: UNIQUE")
}
