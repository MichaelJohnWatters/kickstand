// Package auth owns hand-rolled email/password authentication: bcrypt
// password hashing (password.go), HS256 access tokens + opaque refresh/reset
// tokens (tokens.go, refresh.go, reset.go), and the credential + identity
// store (store.go). Firebase Auth was fully retired on 2026-10-25.
//
// What this file holds:
//   - Identity — the shape every handler reads after the middleware
//     resolves a Bearer token.
//   - The shared error sentinels mapped to HTTP codes by the engine
//     error helper.
package auth

import (
	"errors"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// Identity is what HTTP middleware extracts from a request after
// verifying the Bearer token. Construct tenant.NewScope(db, id.SchoolID)
// to start making tenant-scoped queries. UserID is the local primary key
// that every other table references.
type Identity struct {
	UserID        domain.UserID
	SchoolID      domain.SchoolID
	Role          domain.Role
	AccountStatus domain.AccountStatus
	Email         string
	Name          string
}

var (
	ErrAccountDisabled   = errors.New("auth: account is disabled")
	ErrSessionInvalid    = errors.New("auth: session is invalid, expired, or revoked")
	ErrProfileMissing    = errors.New("auth: no local profile for this identity")
	ErrPasswordTooShort  = errors.New("auth: password too short")
	ErrPasswordTooLong   = errors.New("auth: password too long")
	ErrWeakSigningKey    = errors.New("auth: token signing key must be at least 32 bytes")
	ErrInvalidCredential = errors.New("auth: invalid email or password")
)

// MinPasswordLength is the minimum accepted password length (bytes).
const MinPasswordLength = 8
