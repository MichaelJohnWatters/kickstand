package auth_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
)

func TestResetToken_SingleUse(t *testing.T) {
	ctx := context.Background()
	d := authFixture(t)
	now := time.Now()

	tok, err := auth.CreateResetToken(ctx, d, "sch1", "u1", now)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	uid, sid, err := auth.ConsumeResetToken(ctx, d, tok, now)
	if err != nil || uid != "u1" || sid != "sch1" {
		t.Fatalf("consume: uid=%q sid=%q err=%v", uid, sid, err)
	}
	// Second use of the same token must fail.
	if _, _, err := auth.ConsumeResetToken(ctx, d, tok, now); !errors.Is(err, auth.ErrSessionInvalid) {
		t.Errorf("reuse: got %v, want ErrSessionInvalid", err)
	}
}

func TestResetToken_Expired(t *testing.T) {
	ctx := context.Background()
	d := authFixture(t)
	now := time.Now()
	tok, _ := auth.CreateResetToken(ctx, d, "sch1", "u1", now)
	if _, _, err := auth.ConsumeResetToken(ctx, d, tok, now.Add(2*time.Hour)); !errors.Is(err, auth.ErrSessionInvalid) {
		t.Errorf("expired: got %v, want ErrSessionInvalid", err)
	}
}

func TestResetToken_Garbage(t *testing.T) {
	d := authFixture(t)
	if _, _, err := auth.ConsumeResetToken(context.Background(), d, "not-a-real-token", time.Now()); !errors.Is(err, auth.ErrSessionInvalid) {
		t.Errorf("garbage: got %v, want ErrSessionInvalid", err)
	}
}

func TestSetPassword_ChangesLogin(t *testing.T) {
	ctx := context.Background()
	d := authFixture(t)
	newHash, _ := auth.HashPassword("brand new password")
	if err := auth.SetPassword(ctx, d, "u1", newHash); err != nil {
		t.Fatalf("set password: %v", err)
	}
	if _, err := auth.Authenticate(ctx, d, "sch1", "sam@test.co", "brand new password"); err != nil {
		t.Errorf("new password should authenticate: %v", err)
	}
	if _, err := auth.Authenticate(ctx, d, "sch1", "sam@test.co", "correct horse battery"); !errors.Is(err, auth.ErrInvalidCredential) {
		t.Errorf("old password should fail: %v", err)
	}
}
