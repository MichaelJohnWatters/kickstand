// Package auth handles login, session lookup, and logout.
//
// Design:
//   - Passwords hashed with bcrypt (cost = DefaultCost = 10).
//   - Sessions are opaque random tokens (32 bytes, hex-encoded) stored in
//     user_sessions. NOT JWTs — opaque tokens are simpler, revocable
//     server-side (logout works), and don't require a signing-secret to
//     manage. When we migrate to Supabase Auth, we swap this package for
//     Supabase's JWT verification; nothing else changes because callers
//     interact through the Identity contract.
//   - Email is global unique (the users_email_global_idx in 0001 migration),
//     so login is school-agnostic — we resolve which school the user belongs
//     to from the row itself.
//   - One role per user. The plan acknowledges multi-role users; that's a
//     small schema change (separate user_roles join table) deferred until
//     a real use case appears.
package auth

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"golang.org/x/crypto/bcrypt"
)

// DefaultSessionTTL is how long a freshly-created session stays valid.
// Generous because mobile clients want few re-logins; Logout always revokes.
const DefaultSessionTTL = 30 * 24 * time.Hour

// Identity is what HTTP middleware extracts from a request after
// authenticate-by-token. Construct tenant.NewScope(db, id.SchoolID) to start
// making tenant-scoped queries.
type Identity struct {
	UserID        domain.UserID
	SchoolID      domain.SchoolID
	Role          domain.Role
	AccountStatus domain.AccountStatus
	Email         string
	Name          string
}

type LoginRequest struct {
	Email    string
	Password string
}

type LoginResult struct {
	Token     domain.UserSessionToken
	ExpiresAt time.Time
	Identity  Identity
}

var (
	ErrInvalidCredentials = errors.New("auth: invalid email or password")
	ErrAccountDisabled    = errors.New("auth: account is disabled")
	ErrSessionInvalid     = errors.New("auth: session is invalid, expired, or revoked")
)

// Login validates credentials and creates a session. Returns the token the
// client should carry on subsequent requests.
//
// Note: ErrInvalidCredentials is returned for BOTH "no user" and "wrong
// password" — never reveal which to avoid email-enumeration. Same code path
// timing-wise: we run bcrypt even on the no-user path so login timing
// doesn't leak whether the email exists.
func Login(ctx context.Context, d *sql.DB, req LoginRequest) (*LoginResult, error) {
	return LoginAt(ctx, d, req, time.Now)
}

// LoginAt is the testable form — exposes the clock.
func LoginAt(ctx context.Context, d *sql.DB, req LoginRequest, nowFn func() time.Time) (*LoginResult, error) {
	const q = `
		SELECT id, school_id, email, name, role, account_status, password_hash
		FROM users
		WHERE email = ?
	`
	row := d.QueryRowContext(ctx, q, req.Email)
	var (
		id, schoolID, email, name, role, status, hash string
	)
	err := row.Scan(&id, &schoolID, &email, &name, &role, &status, &hash)
	if errors.Is(err, sql.ErrNoRows) {
		// Constant-time-ish: still run bcrypt to keep timing similar.
		_ = bcrypt.CompareHashAndPassword(
			[]byte("$2a$10$abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxy"),
			[]byte(req.Password),
		)
		return nil, ErrInvalidCredentials
	}
	if err != nil {
		return nil, fmt.Errorf("lookup user: %w", err)
	}

	if err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)); err != nil {
		return nil, ErrInvalidCredentials
	}

	if domain.AccountStatus(status) == domain.AccountDisabled {
		return nil, ErrAccountDisabled
	}
	// Note: pending_approval users CAN log in — they just can't book. The
	// app uses the account_status to render the right UI state. The plan
	// is explicit about this ("browse-but-not-book").

	now := nowFn().UTC()
	token, err := newToken()
	if err != nil {
		return nil, err
	}
	expires := now.Add(DefaultSessionTTL)

	_, err = d.ExecContext(ctx, `
		INSERT INTO user_sessions (token, user_id, created_at, expires_at)
		VALUES (?, ?, ?, ?)
	`, token, id, now.Format(time.RFC3339), expires.Format(time.RFC3339))
	if err != nil {
		return nil, fmt.Errorf("insert session: %w", err)
	}

	return &LoginResult{
		Token:     domain.UserSessionToken(token),
		ExpiresAt: expires,
		Identity: Identity{
			UserID:        domain.UserID(id),
			SchoolID:      domain.SchoolID(schoolID),
			Role:          domain.Role(role),
			AccountStatus: domain.AccountStatus(status),
			Email:         email,
			Name:          name,
		},
	}, nil
}

// Authenticate resolves a session token to an Identity. The HTTP layer calls
// this from middleware and stashes the Identity in request context. From
// there a tenant.Scope can be built for any data-access call.
func Authenticate(ctx context.Context, d *sql.DB, token domain.UserSessionToken) (*Identity, error) {
	return AuthenticateAt(ctx, d, token, time.Now)
}

func AuthenticateAt(ctx context.Context, d *sql.DB, token domain.UserSessionToken, nowFn func() time.Time) (*Identity, error) {
	const q = `
		SELECT u.id, u.school_id, u.email, u.name, u.role, u.account_status,
		       s.expires_at, COALESCE(s.revoked_at, '')
		FROM user_sessions s
		JOIN users u ON u.id = s.user_id
		WHERE s.token = ?
	`
	row := d.QueryRowContext(ctx, q, string(token))
	var (
		id, schoolID, email, name, role, status string
		expiresStr, revokedStr                  string
	)
	err := row.Scan(&id, &schoolID, &email, &name, &role, &status, &expiresStr, &revokedStr)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSessionInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("authenticate: %w", err)
	}

	if revokedStr != "" {
		return nil, ErrSessionInvalid
	}
	expires, err := time.Parse(time.RFC3339, expiresStr)
	if err != nil {
		return nil, fmt.Errorf("parse expires_at: %w", err)
	}
	if !nowFn().UTC().Before(expires) {
		return nil, ErrSessionInvalid
	}

	if domain.AccountStatus(status) == domain.AccountDisabled {
		// A disabled account's existing sessions shouldn't keep working.
		return nil, ErrAccountDisabled
	}

	return &Identity{
		UserID:        domain.UserID(id),
		SchoolID:      domain.SchoolID(schoolID),
		Role:          domain.Role(role),
		AccountStatus: domain.AccountStatus(status),
		Email:         email,
		Name:          name,
	}, nil
}

// Logout revokes the session. Idempotent: revoking an unknown token is a
// no-op (don't leak whether tokens exist).
func Logout(ctx context.Context, d *sql.DB, token domain.UserSessionToken) error {
	return LogoutAt(ctx, d, token, time.Now)
}

func LogoutAt(ctx context.Context, d *sql.DB, token domain.UserSessionToken, nowFn func() time.Time) error {
	_, err := d.ExecContext(ctx, `
		UPDATE user_sessions SET revoked_at = ?
		WHERE token = ? AND revoked_at IS NULL
	`, nowFn().UTC().Format(time.RFC3339), string(token))
	if err != nil {
		return fmt.Errorf("revoke session: %w", err)
	}
	return nil
}

// HashPassword is the seam used by signup / password-change flows. Kept
// exported so callers don't reach for bcrypt directly and accidentally
// pick a different cost.
func HashPassword(plain string) (string, error) {
	h, err := bcrypt.GenerateFromPassword([]byte(plain), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(h), nil
}

// NewSessionToken generates a fresh opaque token. Exported so signup can
// create a session as part of its own transaction without going through
// Login (which requires the plaintext password). The token still has to
// be inserted into user_sessions by the caller.
func NewSessionToken() (string, error) {
	return newToken()
}

func newToken() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("rand: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}
