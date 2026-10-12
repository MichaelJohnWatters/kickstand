package notify_test

import (
	"context"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/notify"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

const (
	testSchool = domain.SchoolID("sch1")
	userA      = domain.UserID("usrA")
	userB      = domain.UserID("usrB")
)

func newTestScope(t *testing.T) *tenant.Scope {
	t.Helper()
	ctx := context.Background()
	d, err := db.Open(t.TempDir() + "/test.db")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := d.ExecContext(ctx,
		`INSERT INTO schools (id, name, region, test_body_label, created_at) VALUES (?, 'Test', 'NI', 'DVA', ?)`,
		string(testSchool), now); err != nil {
		t.Fatalf("insert school: %v", err)
	}
	for _, u := range []domain.UserID{userA, userB} {
		if _, err := d.ExecContext(ctx,
			`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
			 VALUES (?, ?, ?, '', ?, 'student', ?)`,
			string(u), string(testSchool), string(u)+"@test", string(u), now); err != nil {
			t.Fatalf("insert user %s: %v", u, err)
		}
	}
	return tenant.NewScope(d, testSchool)
}

func tokenExists(t *testing.T, scope *tenant.Scope, token string) bool {
	t.Helper()
	var n int
	err := scope.Conn().QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM device_tokens WHERE token = ?`, token).Scan(&n)
	if err != nil {
		t.Fatalf("count tokens: %v", err)
	}
	return n > 0
}

func TestUnregisterDevice_OwnershipGuard(t *testing.T) {
	ctx := context.Background()
	scope := newTestScope(t)
	reg := func(u domain.UserID, tok string) {
		if err := notify.RegisterDevice(ctx, scope, notify.RegisterDeviceRequest{
			UserID: u, SchoolID: testSchool, Token: tok, Platform: "ios",
		}); err != nil {
			t.Fatalf("register %s: %v", tok, err)
		}
	}
	reg(userA, "tokA")
	reg(userB, "tokB")

	// User B must not be able to unregister user A's token even within the
	// same school. The delete simply affects no rows (no error).
	if err := notify.UnregisterDevice(ctx, scope, userB, "tokA"); err != nil {
		t.Fatalf("cross-user unregister: %v", err)
	}
	if !tokenExists(t, scope, "tokA") {
		t.Fatal("user A's token was removed by another user")
	}

	// The owning user can unregister their own token.
	if err := notify.UnregisterDevice(ctx, scope, userA, "tokA"); err != nil {
		t.Fatalf("owner unregister: %v", err)
	}
	if tokenExists(t, scope, "tokA") {
		t.Fatal("token A survived owner unregister")
	}
}
