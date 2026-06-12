package templates_test

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/templates"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// fixture: one school with a course, a location, an instructor, and an
// already-created session_templates row for every Saturday at 09:00.
type fixture struct {
	t      *testing.T
	db     *sql.DB
	scope  *tenant.Scope
	school domain.SchoolID
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	path := t.TempDir() + "/tpl_test.db"
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
			t.Fatalf("seed: %q: %v", q, err)
		}
	}
	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at) VALUES ('school_t','T','NI','DVA',?)`, now)
	exec(`INSERT INTO locations (id, school_id, name, created_at) VALUES ('loc_t','school_t','Belfast',?)`, now)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES ('user_instr','school_t','i@t','','Dave','instructor',?)`, now)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES ('user_admin','school_t','a@t','','Admin','admin',?)`, now)
	exec(`INSERT INTO course_types (id, school_id, code, name, region, required_bike_category,
	          duration_minutes, max_ratio, price_pence, non_teaching, created_at)
	      VALUES ('ct_cbt','school_t','CBT-125','CBT 125','NI','A1',240,4,13000,0,?)`, now)
	return &fixture{
		t:      t,
		db:     d,
		scope:  tenant.NewScope(d, "school_t"),
		school: "school_t",
	}
}

func TestCreate_AndList(t *testing.T) {
	f := newFixture(t)
	tmpl, err := templates.Create(context.Background(), f.scope, templates.CreateRequest{
		CourseTypeID:    "ct_cbt",
		InstructorID:    "user_instr",
		LocationID:      "loc_t",
		Weekday:         6, // Saturday
		StartsAtTime:    "09:00",
		DurationMinutes: 240,
		Capacity:        4,
		CreatedBy:       "user_admin",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if tmpl.InstructorName != "Dave" {
		t.Errorf("instructor lookup not joined: got %q", tmpl.InstructorName)
	}
	list, err := templates.List(context.Background(), f.scope)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 {
		t.Errorf("list = %d, want 1", len(list))
	}
}

func TestMaterialise_GeneratesAndIsIdempotent(t *testing.T) {
	f := newFixture(t)
	_, err := templates.Create(context.Background(), f.scope, templates.CreateRequest{
		CourseTypeID:    "ct_cbt",
		InstructorID:    "user_instr",
		LocationID:      "loc_t",
		Weekday:         6, // Saturday
		StartsAtTime:    "09:00",
		DurationMinutes: 240,
		Capacity:        4,
		CreatedBy:       "user_admin",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	// A 4-week window starting at a known Saturday → exactly 4 sessions.
	from := time.Date(2026, 7, 4, 0, 0, 0, 0, time.UTC) // Saturday
	to := from.AddDate(0, 0, 28)                         // exclusive
	res, err := templates.Materialise(context.Background(), f.scope, from, to, "user_admin")
	if err != nil {
		t.Fatalf("materialise: %v", err)
	}
	if res.CreatedCount != 4 {
		t.Errorf("created = %d, want 4 Saturdays in 28 days", res.CreatedCount)
	}
	if res.MaterialisationID == "" {
		t.Error("expected non-empty MaterialisationID on a successful pass")
	}

	// Re-run is a no-op. No new row written; ID empty.
	res2, err := templates.Materialise(context.Background(), f.scope, from, to, "user_admin")
	if err != nil {
		t.Fatalf("materialise again: %v", err)
	}
	if res2.CreatedCount != 0 {
		t.Errorf("second run created = %d, want 0 (idempotent)", res2.CreatedCount)
	}
	if res2.MaterialisationID != "" {
		t.Errorf("empty pass should not record an ID, got %q", res2.MaterialisationID)
	}

	// And the underlying sessions exist on each Saturday.
	var count int
	if err := f.db.QueryRow(`SELECT COUNT(*) FROM sessions WHERE source_template_id IS NOT NULL`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 4 {
		t.Errorf("session rows = %d, want 4", count)
	}
}

func TestMaterialise_RespectsStartsOnEndsOn(t *testing.T) {
	f := newFixture(t)
	// Template only valid for 2 weeks of a 4-week window.
	_, err := templates.Create(context.Background(), f.scope, templates.CreateRequest{
		CourseTypeID:    "ct_cbt",
		InstructorID:    "user_instr",
		LocationID:      "loc_t",
		Weekday:         6,
		StartsAtTime:    "09:00",
		DurationMinutes: 240,
		Capacity:        4,
		StartsOn:        "2026-07-11",
		EndsOn:          "2026-07-25",
		CreatedBy:       "user_admin",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	from := time.Date(2026, 7, 4, 0, 0, 0, 0, time.UTC)
	to := from.AddDate(0, 0, 28)
	res, err := templates.Materialise(context.Background(), f.scope, from, to, "user_admin")
	if err != nil {
		t.Fatal(err)
	}
	// Saturdays in window: 11, 18 → 2.
	if res.CreatedCount != 2 {
		t.Errorf("created = %d, want 2 (clamped by starts_on/ends_on)", res.CreatedCount)
	}
}

func TestUndoMaterialisation_HappyPath(t *testing.T) {
	f := newFixture(t)
	_, err := templates.Create(context.Background(), f.scope, templates.CreateRequest{
		CourseTypeID:    "ct_cbt",
		InstructorID:    "user_instr",
		LocationID:      "loc_t",
		Weekday:         6,
		StartsAtTime:    "09:00",
		DurationMinutes: 240,
		Capacity:        4,
		CreatedBy:       "user_admin",
	})
	if err != nil {
		t.Fatal(err)
	}
	from := time.Date(2026, 7, 4, 0, 0, 0, 0, time.UTC)
	to := from.AddDate(0, 0, 28)
	res, err := templates.Materialise(context.Background(), f.scope, from, to, "user_admin")
	if err != nil {
		t.Fatal(err)
	}
	if res.MaterialisationID == "" {
		t.Fatal("expected a materialisation id")
	}

	deleted, err := templates.UndoMaterialisation(
		context.Background(), f.scope, res.MaterialisationID, "user_admin")
	if err != nil {
		t.Fatalf("undo: %v", err)
	}
	if deleted != 4 {
		t.Errorf("deleted = %d, want 4", deleted)
	}

	// Pass marked undone, sessions gone.
	var leftover int
	if err := f.db.QueryRow(
		`SELECT COUNT(*) FROM sessions WHERE source_materialisation_id = ?`,
		res.MaterialisationID).Scan(&leftover); err != nil {
		t.Fatal(err)
	}
	if leftover != 0 {
		t.Errorf("expected sessions to be deleted, %d remain", leftover)
	}

	// Second undo is rejected.
	if _, err := templates.UndoMaterialisation(
		context.Background(), f.scope, res.MaterialisationID, "user_admin"); !errors.Is(err, templates.ErrAlreadyUndone) {
		t.Errorf("second undo: want ErrAlreadyUndone, got %v", err)
	}
}

func TestUndoMaterialisation_RefusesWithBookings(t *testing.T) {
	f := newFixture(t)
	// Add a student so we can plant a booking.
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                       VALUES ('user_stu', 'school_t', 'stu@t', '', 'Stu', 'student', 'active', ?)`, now); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO student_profiles (user_id, school_id, cbt_certificate_held, theory_passed)
	                       VALUES ('user_stu', 'school_t', 1, 1)`); err != nil {
		t.Fatal(err)
	}
	_, err := templates.Create(context.Background(), f.scope, templates.CreateRequest{
		CourseTypeID:    "ct_cbt",
		InstructorID:    "user_instr",
		LocationID:      "loc_t",
		Weekday:         6,
		StartsAtTime:    "09:00",
		DurationMinutes: 240,
		Capacity:        4,
		CreatedBy:       "user_admin",
	})
	if err != nil {
		t.Fatal(err)
	}
	from := time.Date(2026, 7, 4, 0, 0, 0, 0, time.UTC)
	to := from.AddDate(0, 0, 28)
	res, err := templates.Materialise(context.Background(), f.scope, from, to, "user_admin")
	if err != nil {
		t.Fatal(err)
	}
	// Plant a manual booking against one of the generated sessions.
	var sessID string
	if err := f.db.QueryRow(
		`SELECT id FROM sessions WHERE source_materialisation_id = ? LIMIT 1`,
		res.MaterialisationID).Scan(&sessID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO bookings (id, school_id, session_id, student_id, status, created_at)
	                       VALUES ('bk_t', 'school_t', ?, 'user_stu', 'booked', ?)`,
		sessID, now); err != nil {
		t.Fatal(err)
	}

	if _, err := templates.UndoMaterialisation(
		context.Background(), f.scope, res.MaterialisationID, "user_admin"); !errors.Is(err, templates.ErrUndoHasBookings) {
		t.Errorf("expected ErrUndoHasBookings, got %v", err)
	}
}
