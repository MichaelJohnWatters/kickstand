// Package auth holds the Identity type and the Firebase verifier.
//
// The package used to own bcrypt password handling and opaque session
// tokens; those were deleted on 2026-06-08 once the all-emulator test
// migration landed and the server stopped issuing or accepting opaque
// tokens. Firebase Auth is now the only identity source.
//
// What remains:
//   - Identity — the shape every handler reads after the middleware
//     resolves a Bearer token.
//   - The shared error sentinels mapped to HTTP codes by the engine
//     error helper.
//   - The Firebase verifier (firebase.go), used by the middleware and
//     by the firebase-signup HTTP handler.
package auth

import (
	"errors"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// Identity is what HTTP middleware extracts from a request after
// verifying the Bearer token. Construct tenant.NewScope(db, id.SchoolID)
// to start making tenant-scoped queries.
//
// FirebaseUID is populated by the Firebase verifier. Handlers shouldn't
// read it directly — UserID is the local primary key that every other
// table references. FirebaseUID is here for the signup handler, which
// needs to write it back into the users row on profile creation.
type Identity struct {
	UserID        domain.UserID
	SchoolID      domain.SchoolID
	Role          domain.Role
	AccountStatus domain.AccountStatus
	Email         string
	Name          string
	FirebaseUID   string
}

var (
	ErrAccountDisabled = errors.New("auth: account is disabled")
	ErrSessionInvalid  = errors.New("auth: session is invalid, expired, or revoked")
	ErrProfileMissing  = errors.New("auth: no local profile for this firebase identity")
)
