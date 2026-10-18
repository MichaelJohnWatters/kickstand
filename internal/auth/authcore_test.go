package auth

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v4"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

func TestHashPassword_RoundTrip(t *testing.T) {
	hash, err := HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if hash == "correct horse battery staple" || !strings.HasPrefix(hash, "$2") {
		t.Fatalf("expected a bcrypt hash, got %q", hash)
	}
	if err := CheckPassword(hash, "correct horse battery staple"); err != nil {
		t.Errorf("correct password should verify, got %v", err)
	}
	if err := CheckPassword(hash, "wrong password here"); !errors.Is(err, ErrInvalidCredential) {
		t.Errorf("wrong password: got %v, want ErrInvalidCredential", err)
	}
}

func TestHashPassword_LengthBounds(t *testing.T) {
	if _, err := HashPassword("short"); !errors.Is(err, ErrPasswordTooShort) {
		t.Errorf("too-short: got %v, want ErrPasswordTooShort", err)
	}
	if _, err := HashPassword(strings.Repeat("a", 100)); !errors.Is(err, ErrPasswordTooLong) {
		t.Errorf("too-long (>72 bytes): got %v, want ErrPasswordTooLong", err)
	}
}

func newTS(t *testing.T) *TokenService {
	t.Helper()
	ts, err := NewTokenService([]byte("0123456789abcdef0123456789abcdef")) // 32 bytes
	if err != nil {
		t.Fatalf("new token service: %v", err)
	}
	return ts
}

func TestNewTokenService_RejectsWeakKey(t *testing.T) {
	if _, err := NewTokenService([]byte("tooshort")); !errors.Is(err, ErrWeakSigningKey) {
		t.Errorf("weak key: got %v, want ErrWeakSigningKey", err)
	}
}

func TestAccessToken_RoundTrip(t *testing.T) {
	ts := newTS(t)
	now := time.Now()
	tok, err := ts.IssueAccess("user-1", time.Hour, now)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	got, err := ts.VerifyAccess(tok)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if got != domain.UserID("user-1") {
		t.Errorf("subject = %q, want user-1", got)
	}
}

func TestAccessToken_RejectsExpired(t *testing.T) {
	ts := newTS(t)
	// Issued an hour ago with a 1-minute TTL → long expired.
	tok, _ := ts.IssueAccess("user-1", time.Minute, time.Now().Add(-time.Hour))
	if _, err := ts.VerifyAccess(tok); !errors.Is(err, ErrSessionInvalid) {
		t.Errorf("expired: got %v, want ErrSessionInvalid", err)
	}
}

func TestAccessToken_RejectsWrongSecret(t *testing.T) {
	ts := newTS(t)
	other, _ := NewTokenService([]byte("ffffffffffffffffffffffffffffffff"))
	tok, _ := other.IssueAccess("user-1", time.Hour, time.Now())
	if _, err := ts.VerifyAccess(tok); !errors.Is(err, ErrSessionInvalid) {
		t.Errorf("wrong secret: got %v, want ErrSessionInvalid", err)
	}
}

func TestAccessToken_RejectsTamperedAndGarbage(t *testing.T) {
	ts := newTS(t)
	tok, _ := ts.IssueAccess("user-1", time.Hour, time.Now())
	tampered := tok[:len(tok)-2] + "xy"
	if _, err := ts.VerifyAccess(tampered); !errors.Is(err, ErrSessionInvalid) {
		t.Errorf("tampered: got %v, want ErrSessionInvalid", err)
	}
	if _, err := ts.VerifyAccess("not.a.jwt"); !errors.Is(err, ErrSessionInvalid) {
		t.Errorf("garbage: got %v, want ErrSessionInvalid", err)
	}
}

// Alg-confusion guard: a token using the "none" algorithm must be rejected,
// not accepted as unsigned.
func TestAccessToken_RejectsNoneAlg(t *testing.T) {
	ts := newTS(t)
	claims := jwt.RegisteredClaims{
		Subject:   "user-1",
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodNone, claims)
	signed, err := tok.SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		t.Fatalf("craft none-token: %v", err)
	}
	if _, err := ts.VerifyAccess(signed); !errors.Is(err, ErrSessionInvalid) {
		t.Errorf("none-alg token must be rejected, got %v", err)
	}
}

func TestNewOpaqueToken_UniqueAndUrlSafe(t *testing.T) {
	a, err := NewOpaqueToken()
	if err != nil {
		t.Fatalf("opaque: %v", err)
	}
	b, _ := NewOpaqueToken()
	if a == b {
		t.Error("two opaque tokens collided")
	}
	if strings.ContainsAny(a, "+/=") {
		t.Errorf("token not URL-safe: %q", a)
	}
}
