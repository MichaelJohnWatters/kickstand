package admin

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// CreateStudentRequest is the engine-level payload for an admin-created
// student. UserID + FirebaseUID are owned by the HTTP layer (which mints
// the Firebase identity first so a duplicate email is rejected by
// Firebase before we touch the database).
type CreateStudentRequest struct {
	UserID      domain.UserID
	FirebaseUID string
	Name        string
	Email       string
	Phone       string
}

// StudentLite is the minimal row the admin students screen needs after a
// create — enough to optimistically append, then refresh from the list
// endpoint for the derived fields (balance, completed, flags).
type StudentLite struct {
	UserID        domain.UserID
	Name          string
	Email         string
	Phone         string
	AccountStatus domain.AccountStatus
}

// CreateStudent inserts a `users` row (role=student, status=active) plus
// a minimal `student_profiles` row. Mirrors InviteInstructor — admin-only,
// caller has already created the Firebase identity and supplies its UID.
//
// The student profile is created with no licence/CBT/theory data; the
// student fills that in later via /me/profile or staff records the
// certificate when they bring it in. CHECK constraints on the profile
// allow NULL for those columns.
func CreateStudent(ctx context.Context, scope *tenant.Scope, req CreateStudentRequest) (*StudentLite, error) {
	if strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.Email) == "" {
		return nil, fmt.Errorf("%w: name and email required", ErrInvalidInput)
	}
	if req.UserID == "" || req.FirebaseUID == "" {
		return nil, fmt.Errorf("%w: userID and firebaseUID required", ErrInvalidInput)
	}
	at := time.Now().UTC().Format(time.RFC3339)
	email := strings.ToLower(strings.TrimSpace(req.Email))

	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		// password_hash is a vestigial NOT NULL column from before the
		// Firebase migration — write empty string. Dropped by a follow-up
		// migration.
		_, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO users (id, school_id, email, phone, password_hash, name, role, account_status, created_at, firebase_uid)
			VALUES (?, ?, ?, ?, '', ?, 'student', 'active', ?, ?)
		`, string(req.UserID), string(scope.SchoolID()), email, req.Phone, req.Name, at, req.FirebaseUID)
		if err != nil {
			if isUniqueViolation(err) {
				return fmt.Errorf("%w: email already in use", ErrConflict)
			}
			return fmt.Errorf("insert student user: %w", err)
		}
		_, err = tx.Conn().ExecContext(ctx, `
			INSERT INTO student_profiles (user_id, school_id, cbt_certificate_held, theory_passed)
			VALUES (?, ?, 0, 0)
		`, string(req.UserID), string(scope.SchoolID()))
		if err != nil {
			return fmt.Errorf("insert profile: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &StudentLite{
		UserID:        req.UserID,
		Name:          req.Name,
		Email:         email,
		Phone:         req.Phone,
		AccountStatus: domain.AccountActive,
	}, nil
}
