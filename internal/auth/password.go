package auth

import (
	"errors"

	"golang.org/x/crypto/bcrypt"
)

// bcryptCost balances resistance to offline cracking against login latency.
// 12 is a sane 2026 default (~250ms on commodity hardware).
const bcryptCost = 12

// HashPassword returns a bcrypt hash (salt + cost + digest, self-describing)
// for storage in users.password_hash. Rejects passwords outside the accepted
// length band — bcrypt silently ignores bytes past 72, so we reject rather
// than hash a surprise-truncated password.
func HashPassword(plain string) (string, error) {
	if len(plain) < MinPasswordLength {
		return "", ErrPasswordTooShort
	}
	b, err := bcrypt.GenerateFromPassword([]byte(plain), bcryptCost)
	if errors.Is(err, bcrypt.ErrPasswordTooLong) {
		return "", ErrPasswordTooLong
	}
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// CheckPassword reports whether plain matches the stored bcrypt hash. Returns
// nil on match, ErrInvalidCredential on mismatch (bcrypt's compare is
// constant-time with respect to the hash). Any other error is a malformed
// stored hash.
func CheckPassword(hash, plain string) error {
	err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(plain))
	if errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
		return ErrInvalidCredential
	}
	return err
}
