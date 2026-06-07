package auth_test

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

type authFixture struct {
	t       *testing.T
	db      *sql.DB
	now     time.Time
	school  domain.SchoolID
	userID  domain.UserID
	email   string
	pw      string
}

func newAuthFixture(t *testing.T) *authFixture {
	t.Helper()
	path := t.TempDir() + "/auth_test.db"
	d, err := db.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })

	ctx := context.Background()
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	f := &authFixture{
		t:      t,
		db:     d,
		now:    time.Date(2026, 6, 6, 9, 0, 0, 0, time.UTC),
		school: domain.SchoolID("school_test"),
		userID: domain.UserID("user_alice"),
		email:  "alice@test",
		pw:     "correct horse battery staple",
	}

	hash, err := auth.HashPassword(f.pw)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}

	if _, err := d.Exec(`INSERT INTO schools (id, name, region, test_body_label, created_at)
	                     VALUES (?, ?, 'NI', 'DVA', ?)`,
		f.school, "Test School", f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                     VALUES (?, ?, ?, ?, 'Alice', 'admin', 'active', ?)`,
		f.userID, f.school, f.email, hash, f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *authFixture) login() (*auth.LoginResult, error) {
	return auth.LoginAt(context.Background(), f.db,
		auth.LoginRequest{Email: f.email, Password: f.pw},
		func() time.Time { return f.now })
}

// ----- Tests -----

func TestLogin_HappyPath(t *testing.T) {
	f := newAuthFixture(t)
	res, err := f.login()
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	if res.Token == "" {
		t.Errorf("expected non-empty token")
	}
	if res.Identity.UserID != f.userID {
		t.Errorf("user id: got %s want %s", res.Identity.UserID, f.userID)
	}
	if res.Identity.SchoolID != f.school {
		t.Errorf("school id: got %s want %s", res.Identity.SchoolID, f.school)
	}
	if res.Identity.Role != domain.RoleAdmin {
		t.Errorf("role: got %s", res.Identity.Role)
	}
}

func TestLogin_WrongPassword(t *testing.T) {
	f := newAuthFixture(t)
	_, err := auth.LoginAt(context.Background(), f.db,
		auth.LoginRequest{Email: f.email, Password: "guess"},
		func() time.Time { return f.now })
	if !errors.Is(err, auth.ErrInvalidCredentials) {
		t.Fatalf("expected ErrInvalidCredentials, got %v", err)
	}
}

func TestLogin_UnknownEmail_SameError(t *testing.T) {
	// Don't reveal whether the email exists. Should match wrong-password.
	f := newAuthFixture(t)
	_, err := auth.LoginAt(context.Background(), f.db,
		auth.LoginRequest{Email: "nobody@test", Password: "anything"},
		func() time.Time { return f.now })
	if !errors.Is(err, auth.ErrInvalidCredentials) {
		t.Fatalf("expected ErrInvalidCredentials, got %v", err)
	}
}

func TestLogin_DisabledAccount_Blocked(t *testing.T) {
	f := newAuthFixture(t)
	if _, err := f.db.Exec(`UPDATE users SET account_status = 'disabled' WHERE id = ?`, f.userID); err != nil {
		t.Fatal(err)
	}
	_, err := f.login()
	if !errors.Is(err, auth.ErrAccountDisabled) {
		t.Fatalf("expected ErrAccountDisabled, got %v", err)
	}
}

func TestLogin_PendingApproval_StillCanLogin(t *testing.T) {
	// Per plan: pending students browse-but-not-book. They can log in to
	// see the pending state. The booking engine separately blocks them.
	f := newAuthFixture(t)
	if _, err := f.db.Exec(`UPDATE users SET account_status = 'pending_approval' WHERE id = ?`, f.userID); err != nil {
		t.Fatal(err)
	}
	res, err := f.login()
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	if res.Identity.AccountStatus != domain.AccountPendingApproval {
		t.Errorf("expected status carried through, got %s", res.Identity.AccountStatus)
	}
}

func TestAuthenticate_RoundTrip(t *testing.T) {
	f := newAuthFixture(t)
	logged, err := f.login()
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	id, err := auth.AuthenticateAt(context.Background(), f.db, logged.Token,
		func() time.Time { return f.now.Add(time.Hour) })
	if err != nil {
		t.Fatalf("authenticate: %v", err)
	}
	if id.UserID != f.userID || id.SchoolID != f.school {
		t.Errorf("identity mismatch: %+v", id)
	}
}

func TestAuthenticate_UnknownToken(t *testing.T) {
	f := newAuthFixture(t)
	_, err := auth.AuthenticateAt(context.Background(), f.db, "deadbeef",
		func() time.Time { return f.now })
	if !errors.Is(err, auth.ErrSessionInvalid) {
		t.Fatalf("expected ErrSessionInvalid, got %v", err)
	}
}

func TestAuthenticate_Expired(t *testing.T) {
	f := newAuthFixture(t)
	logged, err := f.login()
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	_, err = auth.AuthenticateAt(context.Background(), f.db, logged.Token,
		func() time.Time { return f.now.Add(auth.DefaultSessionTTL + time.Minute) })
	if !errors.Is(err, auth.ErrSessionInvalid) {
		t.Fatalf("expected ErrSessionInvalid for expired session, got %v", err)
	}
}

func TestLogout_RevokesSession(t *testing.T) {
	f := newAuthFixture(t)
	logged, err := f.login()
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	if err := auth.LogoutAt(context.Background(), f.db, logged.Token,
		func() time.Time { return f.now.Add(time.Hour) }); err != nil {
		t.Fatalf("logout: %v", err)
	}
	_, err = auth.AuthenticateAt(context.Background(), f.db, logged.Token,
		func() time.Time { return f.now.Add(2 * time.Hour) })
	if !errors.Is(err, auth.ErrSessionInvalid) {
		t.Fatalf("expected ErrSessionInvalid after logout, got %v", err)
	}
}

func TestLogout_UnknownToken_IsNoOp(t *testing.T) {
	f := newAuthFixture(t)
	if err := auth.LogoutAt(context.Background(), f.db, "nope",
		func() time.Time { return f.now }); err != nil {
		t.Fatalf("logout of unknown should be a no-op, got %v", err)
	}
}

func TestAuthenticate_AccountLaterDisabled(t *testing.T) {
	f := newAuthFixture(t)
	logged, err := f.login()
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	// Admin disables the account post-login. The existing token must stop working.
	if _, err := f.db.Exec(`UPDATE users SET account_status = 'disabled' WHERE id = ?`, f.userID); err != nil {
		t.Fatal(err)
	}
	_, err = auth.AuthenticateAt(context.Background(), f.db, logged.Token,
		func() time.Time { return f.now.Add(time.Hour) })
	if !errors.Is(err, auth.ErrAccountDisabled) {
		t.Fatalf("expected ErrAccountDisabled, got %v", err)
	}
}
