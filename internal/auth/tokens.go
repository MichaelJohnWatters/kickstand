package auth

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v4"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// TokenService mints and verifies short-lived access tokens — the hand-rolled
// replacement for Firebase ID tokens. Tokens are HS256 JWTs carrying only the
// user id (subject) + expiry; the middleware re-loads the authoritative
// identity (role, status, email) from the DB on each request, so a disabled
// or role-changed account takes effect immediately and nothing stale is
// trusted from the token itself.
type TokenService struct {
	secret []byte
}

// NewTokenService builds a service from a signing secret (≥32 bytes). Supply
// it from a secret store / env in production, never a hardcoded value.
func NewTokenService(secret []byte) (*TokenService, error) {
	if len(secret) < 32 {
		return nil, ErrWeakSigningKey
	}
	return &TokenService{secret: secret}, nil
}

// IssueAccess returns a signed access token for userID, valid for ttl from now.
func (t *TokenService) IssueAccess(userID domain.UserID, ttl time.Duration, now time.Time) (string, error) {
	claims := jwt.RegisteredClaims{
		Subject:   string(userID),
		IssuedAt:  jwt.NewNumericDate(now),
		NotBefore: jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(t.secret)
}

// VerifyAccess validates signature + expiry and returns the subject (user id).
// Returns ErrSessionInvalid for anything wrong — bad signature, expired,
// malformed, or a non-HMAC algorithm (guards against alg-confusion attacks).
func (t *TokenService) VerifyAccess(tokenStr string) (domain.UserID, error) {
	claims := &jwt.RegisteredClaims{}
	_, err := jwt.ParseWithClaims(tokenStr, claims, func(tok *jwt.Token) (any, error) {
		if _, ok := tok.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method %v", tok.Header["alg"])
		}
		return t.secret, nil
	})
	if err != nil || claims.Subject == "" {
		return "", ErrSessionInvalid
	}
	return domain.UserID(claims.Subject), nil
}

// NewOpaqueToken returns a 256-bit URL-safe random token for password-reset and
// email-verification links. Store a hash of it (not the token) with an expiry;
// treat it as single-use.
func NewOpaqueToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
