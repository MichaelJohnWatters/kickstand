package auth

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// ResetTokenTTL is how long a password-reset link stays valid.
const ResetTokenTTL = time.Hour

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// CreateResetToken mints a single-use password-reset token for a user, stores
// only its hash + expiry, and returns the plaintext token to put in the email
// link. Call only for a user that exists.
func CreateResetToken(ctx context.Context, db *sql.DB, schoolID domain.SchoolID, userID domain.UserID, now time.Time) (string, error) {
	token, err := NewOpaqueToken()
	if err != nil {
		return "", err
	}
	_, err = db.ExecContext(ctx, `
		INSERT INTO auth_tokens (token_hash, school_id, user_id, purpose, expires_at, created_at)
		VALUES (?, ?, ?, 'password_reset', ?, ?)
	`, hashToken(token), string(schoolID), string(userID),
		now.Add(ResetTokenTTL).UTC().Format(time.RFC3339), now.UTC().Format(time.RFC3339))
	if err != nil {
		return "", err
	}
	return token, nil
}

// ConsumeResetToken validates a password-reset token and marks it used
// (single-use, atomically). Returns the user it belongs to. ErrSessionInvalid
// if the token is unknown, expired, or already used.
func ConsumeResetToken(ctx context.Context, db *sql.DB, token string, now time.Time) (domain.UserID, domain.SchoolID, error) {
	th := hashToken(token)
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()

	var userID, schoolID, expiresAt string
	err = tx.QueryRowContext(ctx, `
		SELECT user_id, school_id, expires_at FROM auth_tokens
		WHERE token_hash = ? AND purpose = 'password_reset' AND used_at IS NULL
	`, th).Scan(&userID, &schoolID, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrSessionInvalid
	}
	if err != nil {
		return "", "", err
	}
	exp, _ := time.Parse(time.RFC3339, expiresAt)
	if now.UTC().After(exp) {
		return "", "", ErrSessionInvalid
	}
	// Mark used under the immediate-tx write lock — a concurrent consume sees
	// rows=0 and loses the race.
	res, err := tx.ExecContext(ctx,
		`UPDATE auth_tokens SET used_at = ? WHERE token_hash = ? AND used_at IS NULL`,
		now.UTC().Format(time.RFC3339), th)
	if err != nil {
		return "", "", err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return "", "", ErrSessionInvalid
	}
	if err := tx.Commit(); err != nil {
		return "", "", err
	}
	return domain.UserID(userID), domain.SchoolID(schoolID), nil
}

// SetPassword updates a user's stored password hash.
func SetPassword(ctx context.Context, db *sql.DB, userID domain.UserID, newHash string) error {
	_, err := db.ExecContext(ctx, `UPDATE users SET password_hash = ? WHERE id = ?`, newHash, string(userID))
	return err
}
