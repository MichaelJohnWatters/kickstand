package auth

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// dummyHash is a valid bcrypt hash used to equalise timing on the "no such
// user" path so an attacker can't enumerate accounts by response time.
const dummyHash = "$2a$12$C6UzMDM.H6dfI/f/IKcEeO3YgtTZQ1mBVY8r7xW6Qh7pQb1vJ9t2m"

// Authenticate verifies an email + password within a school and returns the
// identity. Returns ErrInvalidCredential for a bad email/password (no
// user-enumeration leak), ErrAccountDisabled for a correct password on a
// disabled account.
func Authenticate(ctx context.Context, db *sql.DB, schoolID domain.SchoolID, email, password string) (*Identity, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	var id, name, role, status, hash string
	err := db.QueryRowContext(ctx, `
		SELECT id, name, role, account_status, COALESCE(password_hash, '')
		FROM users WHERE school_id = ? AND email = ?
	`, string(schoolID), email).Scan(&id, &name, &role, &status, &hash)
	if errors.Is(err, sql.ErrNoRows) {
		_ = CheckPassword(dummyHash, password) // equalise timing
		return nil, ErrInvalidCredential
	}
	if err != nil {
		return nil, err
	}
	if hash == "" {
		// User has no local password (e.g. a Firebase-only account mid-migration).
		_ = CheckPassword(dummyHash, password)
		return nil, ErrInvalidCredential
	}
	if err := CheckPassword(hash, password); err != nil {
		return nil, ErrInvalidCredential
	}
	if domain.AccountStatus(status) == domain.AccountDisabled {
		return nil, ErrAccountDisabled
	}
	return &Identity{
		UserID:        domain.UserID(id),
		SchoolID:      schoolID,
		Role:          domain.Role(role),
		AccountStatus: domain.AccountStatus(status),
		Email:         email,
		Name:          name,
	}, nil
}

// LoadByUserID returns the identity for a user id. The token middleware calls
// this on every request so the authoritative role/status come from the DB, not
// a stale token. ErrProfileMissing if the user is gone; ErrAccountDisabled if
// disabled.
func LoadByUserID(ctx context.Context, db *sql.DB, userID domain.UserID) (*Identity, error) {
	var schoolID, email, name, role, status string
	err := db.QueryRowContext(ctx, `
		SELECT school_id, email, name, role, account_status
		FROM users WHERE id = ?
	`, string(userID)).Scan(&schoolID, &email, &name, &role, &status)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrProfileMissing
	}
	if err != nil {
		return nil, err
	}
	if domain.AccountStatus(status) == domain.AccountDisabled {
		return nil, ErrAccountDisabled
	}
	return &Identity{
		UserID:        userID,
		SchoolID:      domain.SchoolID(schoolID),
		Role:          domain.Role(role),
		AccountStatus: domain.AccountStatus(status),
		Email:         email,
		Name:          name,
	}, nil
}
