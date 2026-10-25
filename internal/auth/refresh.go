package auth

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// RefreshTokenTTL is how long a refresh token stays valid. Access tokens are
// short-lived (accessTTL in the http layer); the client trades a refresh token
// for a new access token via /auth/refresh until the refresh token itself
// expires, at which point the user signs in again.
const RefreshTokenTTL = 30 * 24 * time.Hour

// CreateRefreshToken mints a refresh token for a user, stores only its hash +
// expiry (purpose='refresh'), and returns the plaintext token to hand to the
// client. Single-use: RotateRefreshToken consumes it and issues a replacement.
func CreateRefreshToken(ctx context.Context, db *sql.DB, schoolID domain.SchoolID, userID domain.UserID, now time.Time) (string, error) {
	return createRefreshToken(ctx, db, schoolID, userID, now)
}

// RotateRefreshToken validates a refresh token, marks it used, and issues a
// fresh refresh token for the same user — all atomically, so a token can never
// mint two replacements (rotation). Returns the owning user + the new token.
// ErrSessionInvalid if the token is unknown, expired, or already used.
func RotateRefreshToken(ctx context.Context, db *sql.DB, token string, now time.Time) (domain.UserID, domain.SchoolID, string, error) {
	th := hashToken(token)
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return "", "", "", err
	}
	defer tx.Rollback()

	var userID, schoolID, expiresAt string
	err = tx.QueryRowContext(ctx, `
		SELECT user_id, school_id, expires_at FROM auth_tokens
		WHERE token_hash = ? AND purpose = 'refresh' AND used_at IS NULL
	`, th).Scan(&userID, &schoolID, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", "", ErrSessionInvalid
	}
	if err != nil {
		return "", "", "", err
	}
	exp, _ := time.Parse(time.RFC3339, expiresAt)
	if now.UTC().After(exp) {
		return "", "", "", ErrSessionInvalid
	}
	// Consume under the immediate-tx write lock — a concurrent rotate sees
	// rows=0 and loses the race (the old token can't mint two replacements).
	res, err := tx.ExecContext(ctx,
		`UPDATE auth_tokens SET used_at = ? WHERE token_hash = ? AND used_at IS NULL`,
		now.UTC().Format(time.RFC3339), th)
	if err != nil {
		return "", "", "", err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return "", "", "", ErrSessionInvalid
	}
	newToken, err := createRefreshToken(ctx, tx, domain.SchoolID(schoolID), domain.UserID(userID), now)
	if err != nil {
		return "", "", "", err
	}
	if err := tx.Commit(); err != nil {
		return "", "", "", err
	}
	return domain.UserID(userID), domain.SchoolID(schoolID), newToken, nil
}

// execer is the subset of *sql.DB / *sql.Tx that createRefreshToken needs, so
// it can run standalone or inside the rotation transaction.
type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func createRefreshToken(ctx context.Context, e execer, schoolID domain.SchoolID, userID domain.UserID, now time.Time) (string, error) {
	token, err := NewOpaqueToken()
	if err != nil {
		return "", err
	}
	_, err = e.ExecContext(ctx, `
		INSERT INTO auth_tokens (token_hash, school_id, user_id, purpose, expires_at, created_at)
		VALUES (?, ?, ?, 'refresh', ?, ?)
	`, hashToken(token), string(schoolID), string(userID),
		now.Add(RefreshTokenTTL).UTC().Format(time.RFC3339), now.UTC().Format(time.RFC3339))
	if err != nil {
		return "", err
	}
	return token, nil
}
