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

func authFixture(t *testing.T) *sql.DB {
	t.Helper()
	ctx := context.Background()
	d, err := db.Open(t.TempDir() + "/a.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	hash, err := auth.HashPassword("correct horse battery")
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	exec := func(q string, a ...any) {
		if _, err := d.ExecContext(ctx, q, a...); err != nil {
			t.Fatalf("seed %q: %v", q, err)
		}
	}
	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at) VALUES ('sch1','T','NI','DVA',?)`, now)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES ('u1','sch1','sam@test.co',?,'Sam','owner','active',?)`, hash, now)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES ('u2','sch1','dis@test.co',?,'Dis','student','disabled',?)`, hash, now)
	return d
}

func TestAuthenticate(t *testing.T) {
	ctx := context.Background()
	d := authFixture(t)

	// Happy path (email case-insensitive).
	id, err := auth.Authenticate(ctx, d, "sch1", "SAM@test.co", "correct horse battery")
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	if id.UserID != "u1" || id.Role != domain.RoleOwner || id.Email != "sam@test.co" {
		t.Errorf("identity = %+v", id)
	}

	// Wrong password + unknown email → same ErrInvalidCredential (no enumeration).
	if _, err := auth.Authenticate(ctx, d, "sch1", "sam@test.co", "nope nope nope"); !errors.Is(err, auth.ErrInvalidCredential) {
		t.Errorf("wrong pw: got %v", err)
	}
	if _, err := auth.Authenticate(ctx, d, "sch1", "ghost@test.co", "whatever here"); !errors.Is(err, auth.ErrInvalidCredential) {
		t.Errorf("unknown email: got %v", err)
	}

	// Correct password on a disabled account → ErrAccountDisabled.
	if _, err := auth.Authenticate(ctx, d, "sch1", "dis@test.co", "correct horse battery"); !errors.Is(err, auth.ErrAccountDisabled) {
		t.Errorf("disabled: got %v", err)
	}
}

func TestLoadByUserID(t *testing.T) {
	ctx := context.Background()
	d := authFixture(t)

	id, err := auth.LoadByUserID(ctx, d, "u1")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if id.SchoolID != "sch1" || id.Role != domain.RoleOwner {
		t.Errorf("identity = %+v", id)
	}
	if _, err := auth.LoadByUserID(ctx, d, "ghost"); !errors.Is(err, auth.ErrProfileMissing) {
		t.Errorf("unknown id: got %v", err)
	}
	if _, err := auth.LoadByUserID(ctx, d, "u2"); !errors.Is(err, auth.ErrAccountDisabled) {
		t.Errorf("disabled: got %v", err)
	}
}
