package closures_test

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/closures"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

type fixture struct {
	t     *testing.T
	db    *sql.DB
	scope *tenant.Scope
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	path := t.TempDir() + "/cls_test.db"
	d, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := d.Exec(q, args...); err != nil {
			t.Fatalf("seed %q: %v", q, err)
		}
	}
	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at)
	      VALUES ('school_t','T','NI','DVA',?)`, now)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES ('user_admin','school_t','a@t','','Admin','admin',?)`, now)
	return &fixture{t: t, db: d, scope: tenant.NewScope(d, "school_t")}
}

func TestCreate_AndList(t *testing.T) {
	f := newFixture(t)
	c, err := closures.Create(context.Background(), f.scope, closures.CreateRequest{
		FromDate:  "2026-12-25",
		ToDate:    "2026-12-25",
		Label:     "Christmas Day",
		CreatedBy: "user_admin",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if c.ID == "" {
		t.Error("expected an id")
	}
	list, err := closures.List(context.Background(), f.scope)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].Label != "Christmas Day" {
		t.Errorf("list = %v", list)
	}
}

func TestCreate_RejectsInvertedRange(t *testing.T) {
	f := newFixture(t)
	_, err := closures.Create(context.Background(), f.scope, closures.CreateRequest{
		FromDate:  "2026-12-26",
		ToDate:    "2026-12-25",
		Label:     "Backwards",
		CreatedBy: "user_admin",
	})
	if !errors.Is(err, closures.ErrInvalidInput) {
		t.Fatalf("want ErrInvalidInput, got %v", err)
	}
}

func TestIsClosed(t *testing.T) {
	f := newFixture(t)
	if _, err := closures.Create(context.Background(), f.scope, closures.CreateRequest{
		FromDate:  "2026-12-24",
		ToDate:    "2026-12-26",
		Label:     "Christmas",
		CreatedBy: "user_admin",
	}); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		date  string
		want  bool
	}{
		{"2026-12-23", false},
		{"2026-12-24", true},
		{"2026-12-25", true},
		{"2026-12-26", true},
		{"2026-12-27", false},
	}
	for _, c := range cases {
		got, err := closures.IsClosed(context.Background(), f.scope, c.date)
		if err != nil {
			t.Fatalf("IsClosed(%s): %v", c.date, err)
		}
		if got != c.want {
			t.Errorf("IsClosed(%s) = %v, want %v", c.date, got, c.want)
		}
	}
}

func TestList_ReportsAffectedSessions(t *testing.T) {
	f := newFixture(t)
	// Seed a course, instructor, location, and a session falling inside
	// the closure window so we can assert SessionsAffected is non-zero.
	now := time.Now().UTC().Format(time.RFC3339)
	_, _ = f.db.Exec(`INSERT INTO locations (id, school_id, name, created_at) VALUES ('loc_t','school_t','Belfast',?)`, now)
	_, _ = f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	                 VALUES ('user_instr','school_t','i@t','','Dave','instructor',?)`, now)
	_, _ = f.db.Exec(`INSERT INTO course_types (id, school_id, code, name, region, required_bike_category,
	                     duration_minutes, max_ratio, price_pence, non_teaching, created_at)
	                 VALUES ('ct_cbt','school_t','CBT-125','CBT 125','NI','A1',240,4,0,0,?)`, now)
	// Session on 2026-12-25 at noon UTC.
	_, _ = f.db.Exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id,
	                     starts_at, ends_at, capacity, created_at)
	                 VALUES ('sess_xmas','school_t','ct_cbt','user_instr','loc_t',
	                         '2026-12-25T12:00:00Z','2026-12-25T16:00:00Z',4,?)`, now)
	if _, err := closures.Create(context.Background(), f.scope, closures.CreateRequest{
		FromDate:  "2026-12-25",
		ToDate:    "2026-12-25",
		Label:     "Christmas Day",
		CreatedBy: "user_admin",
	}); err != nil {
		t.Fatal(err)
	}
	list, err := closures.List(context.Background(), f.scope)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].SessionsAffected != 1 {
		t.Errorf("want SessionsAffected=1, got %+v", list)
	}
}

func TestDelete(t *testing.T) {
	f := newFixture(t)
	c, _ := closures.Create(context.Background(), f.scope, closures.CreateRequest{
		FromDate:  "2026-12-25",
		ToDate:    "2026-12-25",
		Label:     "Christmas",
		CreatedBy: "user_admin",
	})
	if err := closures.Delete(context.Background(), f.scope, c.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if err := closures.Delete(context.Background(), f.scope, c.ID); !errors.Is(err, closures.ErrNotFound) {
		t.Fatalf("second delete: want ErrNotFound, got %v", err)
	}
	_ = domain.SchoolID("school_t") // keep import; would be unused without
}
