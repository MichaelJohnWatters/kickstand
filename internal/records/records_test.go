package records_test

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/records"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

type fixture struct {
	t       *testing.T
	db      *sql.DB
	scope   *tenant.Scope
	now     time.Time
	school  domain.SchoolID
	admin   domain.UserID
	student domain.UserID
	bike    domain.BikeID
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	d, err := db.Open(t.TempDir() + "/r.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	f := &fixture{
		t: t, db: d,
		now:     time.Date(2026, 6, 6, 9, 0, 0, 0, time.UTC),
		school:  "school_t",
		admin:   "user_admin",
		student: "user_stu",
		bike:    "bike_t",
	}
	f.scope = tenant.NewScope(d, f.school)
	at := f.now.Format(time.RFC3339)
	exec := func(q string, args ...any) {
		if _, err := f.db.Exec(q, args...); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at)
	      VALUES (?, ?, 'NI', 'DVA', ?)`, f.school, "T", at)
	exec(`INSERT INTO locations (id, school_id, name, created_at) VALUES ('loc_t', ?, 'Belfast', ?)`,
		f.school, at)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES (?, ?, ?, '', ?, 'admin', ?)`, f.admin, f.school, "a@t", "A", at)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES (?, ?, ?, '', ?, 'student', 'active', ?)`, f.student, f.school, "s@t", "S", at)
	exec(`INSERT INTO bikes (id, school_id, category, transmission, status, home_location_id, current_location_id, created_at)
	      VALUES (?, ?, 'A1', 'manual', 'ready', 'loc_t', 'loc_t', ?)`, f.bike, f.school, at)
	return f
}

// ----- Incidents -----

func TestLogIncident_BasicHappyPath(t *testing.T) {
	f := newFixture(t)
	inc, err := records.LogIncident(context.Background(), f.scope, records.LogIncidentRequest{
		BikeID:      f.bike,
		StudentID:   f.student,
		Description: "Dropped at low speed; no damage",
		CreatedBy:   f.admin,
	})
	if err != nil {
		t.Fatal(err)
	}
	if inc.ID == "" || inc.TookBikeOffline {
		t.Errorf("unexpected: %+v", inc)
	}
}

func TestLogIncident_TakesBikeOffline(t *testing.T) {
	f := newFixture(t)
	_, err := records.LogIncident(context.Background(), f.scope, records.LogIncidentRequest{
		BikeID:          f.bike,
		StudentID:       f.student,
		Description:     "Brake pad shattered",
		TakeBikeOffline: true,
		OfflineReason:   "broken",
		CreatedBy:       f.admin,
	})
	if err != nil {
		t.Fatal(err)
	}
	// Bike should be offline + a bike_unavailability row should exist.
	var status string
	f.db.QueryRow(`SELECT status FROM bikes WHERE id = ?`, f.bike).Scan(&status)
	if status != "offline" {
		t.Errorf("expected offline, got %s", status)
	}
	var n int
	f.db.QueryRow(`SELECT COUNT(*) FROM bike_unavailability WHERE bike_id = ?`, f.bike).Scan(&n)
	if n != 1 {
		t.Errorf("expected 1 unavailability row, got %d", n)
	}
}

func TestLogIncident_TakeOfflineWithoutBikeRejected(t *testing.T) {
	f := newFixture(t)
	_, err := records.LogIncident(context.Background(), f.scope, records.LogIncidentRequest{
		Description: "x", TakeBikeOffline: true, CreatedBy: f.admin,
	})
	if !errors.Is(err, records.ErrInvalidInput) {
		t.Errorf("expected ErrInvalidInput, got %v", err)
	}
}

func TestListIncidents_FilterByStudent(t *testing.T) {
	f := newFixture(t)
	// Two incidents — one for student, one bike-only.
	if _, err := records.LogIncident(context.Background(), f.scope, records.LogIncidentRequest{
		BikeID: f.bike, StudentID: f.student, Description: "1", CreatedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := records.LogIncident(context.Background(), f.scope, records.LogIncidentRequest{
		BikeID: f.bike, Description: "2 — no rider", CreatedBy: f.admin,
	}); err != nil {
		t.Fatal(err)
	}
	all, _ := records.ListIncidents(context.Background(), f.scope, "")
	if len(all) != 2 {
		t.Errorf("expected 2 all, got %d", len(all))
	}
	mine, _ := records.ListIncidents(context.Background(), f.scope, f.student)
	if len(mine) != 1 {
		t.Errorf("expected 1 for student, got %d", len(mine))
	}
}

// ----- Notes -----

func TestAddNote_HappyPath(t *testing.T) {
	f := newFixture(t)
	n, err := records.AddNote(context.Background(), f.scope, records.AddNoteRequest{
		StudentID: f.student,
		Kind:      records.NoteSafetyFlag,
		Body:      "Requires low-seat bike",
		CreatedBy: f.admin,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !n.IsActive {
		t.Errorf("expected active note")
	}
}

func TestAddNote_InvalidKindRejected(t *testing.T) {
	f := newFixture(t)
	_, err := records.AddNote(context.Background(), f.scope, records.AddNoteRequest{
		StudentID: f.student, Kind: "rumour", Body: "x", CreatedBy: f.admin,
	})
	if !errors.Is(err, records.ErrInvalidKind) {
		t.Errorf("expected ErrInvalidKind, got %v", err)
	}
}

func TestAddNote_RequiresStudent(t *testing.T) {
	f := newFixture(t)
	_, err := records.AddNote(context.Background(), f.scope, records.AddNoteRequest{
		StudentID: "nope", Kind: records.NoteSafetyFlag, Body: "x", CreatedBy: f.admin,
	})
	if !errors.Is(err, records.ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestListNotes_FilterByKind(t *testing.T) {
	f := newFixture(t)
	for _, kind := range []string{records.NoteSafetyFlag, records.NoteSafetyFlag, records.NoteProgressNote} {
		if _, err := records.AddNote(context.Background(), f.scope, records.AddNoteRequest{
			StudentID: f.student, Kind: kind, Body: "x", CreatedBy: f.admin,
		}); err != nil {
			t.Fatal(err)
		}
	}
	flags, _ := records.ListNotes(context.Background(), f.scope, f.student, records.NoteSafetyFlag)
	if len(flags) != 2 {
		t.Errorf("expected 2 flags, got %d", len(flags))
	}
	all, _ := records.ListNotes(context.Background(), f.scope, f.student, "")
	if len(all) != 3 {
		t.Errorf("expected 3 all, got %d", len(all))
	}
}

func TestDeactivateNote(t *testing.T) {
	f := newFixture(t)
	n, _ := records.AddNote(context.Background(), f.scope, records.AddNoteRequest{
		StudentID: f.student, Kind: records.NoteSafetyFlag, Body: "x", CreatedBy: f.admin,
	})
	if err := records.DeactivateNote(context.Background(), f.scope, n.ID); err != nil {
		t.Fatal(err)
	}
	notes, _ := records.ListNotes(context.Background(), f.scope, f.student, "")
	if notes[0].IsActive {
		t.Errorf("expected inactive after deactivation")
	}
}

// ----- External tests -----

func TestRecordExternalTest_NIPath(t *testing.T) {
	f := newFixture(t)
	tst, err := records.RecordExternalTest(context.Background(), f.scope, records.RecordExternalTestRequest{
		StudentID:   f.student,
		TestType:    "practical",
		Region:      domain.RegionNI,
		ScheduledAt: f.now.Add(48 * time.Hour),
		Outcome:     "booked",
	})
	if err != nil {
		t.Fatalf("record: %v", err)
	}
	if tst.AttemptNumber != 1 {
		t.Errorf("expected attempt 1, got %d", tst.AttemptNumber)
	}
}

func TestRecordExternalTest_AttemptNumberIncrements(t *testing.T) {
	f := newFixture(t)
	for i := 0; i < 3; i++ {
		if _, err := records.RecordExternalTest(context.Background(), f.scope, records.RecordExternalTestRequest{
			StudentID: f.student, TestType: "practical", Region: domain.RegionNI,
			Outcome: "fail",
		}); err != nil {
			t.Fatal(err)
		}
	}
	tests, _ := records.ListExternalTests(context.Background(), f.scope, f.student)
	if len(tests) != 3 {
		t.Fatalf("expected 3 attempts, got %d", len(tests))
	}
	// Latest scheduled first; but since scheduled_at is zero, order falls
	// back to created_at desc. So attempt 3 is at index 0.
	if tests[0].AttemptNumber != 3 {
		t.Errorf("expected attempt 3 at top, got %d", tests[0].AttemptNumber)
	}
}

func TestRecordExternalTest_RejectsMod1ForNI(t *testing.T) {
	f := newFixture(t)
	_, err := records.RecordExternalTest(context.Background(), f.scope, records.RecordExternalTestRequest{
		StudentID: f.student, TestType: "mod1", Region: domain.RegionNI, Outcome: "booked",
	})
	if !errors.Is(err, records.ErrInvalidInput) {
		t.Errorf("expected ErrInvalidInput for mod1 in NI, got %v", err)
	}
}

func TestRecordExternalTest_InvalidOutcome(t *testing.T) {
	f := newFixture(t)
	_, err := records.RecordExternalTest(context.Background(), f.scope, records.RecordExternalTestRequest{
		StudentID: f.student, TestType: "practical", Region: domain.RegionNI, Outcome: "maybe",
	})
	if !errors.Is(err, records.ErrInvalidInput) {
		t.Errorf("expected ErrInvalidInput, got %v", err)
	}
}

func TestUpdateOutcome(t *testing.T) {
	f := newFixture(t)
	tst, _ := records.RecordExternalTest(context.Background(), f.scope, records.RecordExternalTestRequest{
		StudentID: f.student, TestType: "practical", Region: domain.RegionNI, Outcome: "booked",
	})
	if err := records.UpdateOutcome(context.Background(), f.scope, tst.ID, "pass", "first try!"); err != nil {
		t.Fatal(err)
	}
	tests, _ := records.ListExternalTests(context.Background(), f.scope, f.student)
	if tests[0].Outcome != "pass" {
		t.Errorf("expected pass after update, got %s", tests[0].Outcome)
	}
}
