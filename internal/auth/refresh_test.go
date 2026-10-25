package auth_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
)

func TestRefreshToken_RotatesSingleUse(t *testing.T) {
	ctx := context.Background()
	d := authFixture(t)
	now := time.Now()

	tok, err := auth.CreateRefreshToken(ctx, d, "sch1", "u1", now)
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	uid, sid, next, err := auth.RotateRefreshToken(ctx, d, tok, now)
	if err != nil || uid != "u1" || sid != "sch1" {
		t.Fatalf("rotate: uid=%q sid=%q err=%v", uid, sid, err)
	}
	if next == "" || next == tok {
		t.Fatalf("rotate should return a fresh token, got %q (old %q)", next, tok)
	}

	// The old token is consumed — reusing it must fail.
	if _, _, _, err := auth.RotateRefreshToken(ctx, d, tok, now); !errors.Is(err, auth.ErrSessionInvalid) {
		t.Errorf("reuse of old token: got %v, want ErrSessionInvalid", err)
	}
	// The new token still works.
	if _, _, _, err := auth.RotateRefreshToken(ctx, d, next, now); err != nil {
		t.Errorf("new token should rotate: %v", err)
	}
}

func TestRefreshToken_Expired(t *testing.T) {
	ctx := context.Background()
	d := authFixture(t)
	now := time.Now()
	tok, _ := auth.CreateRefreshToken(ctx, d, "sch1", "u1", now)
	if _, _, _, err := auth.RotateRefreshToken(ctx, d, tok, now.Add(auth.RefreshTokenTTL+time.Hour)); !errors.Is(err, auth.ErrSessionInvalid) {
		t.Errorf("expired: got %v, want ErrSessionInvalid", err)
	}
}

func TestRefreshToken_Garbage(t *testing.T) {
	d := authFixture(t)
	if _, _, _, err := auth.RotateRefreshToken(context.Background(), d, "not-a-token", time.Now()); !errors.Is(err, auth.ErrSessionInvalid) {
		t.Errorf("garbage: got %v, want ErrSessionInvalid", err)
	}
}
