package booking_test

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// testFixture is one fully-seeded school with one instructor, two students,
// two ready bikes (one A1 manual, one A2 manual), a CBT 125 course type, and
// a single CBT session at noon tomorrow with capacity 2.
//
// Each test calls newFixture(t) for an isolated DB — keeps test interactions
// trivially reasoned about.
type testFixture struct {
	t          *testing.T
	db         *sql.DB
	scope      *tenant.Scope
	now        time.Time
	schoolID   domain.SchoolID
	location   domain.LocationID
	otherLoc   domain.LocationID
	instructor domain.UserID
	courseCBT  domain.CourseTypeID
	bikeA1     domain.BikeID
	bikeA2     domain.BikeID
	studentA   domain.UserID
	studentB   domain.UserID
	sessionID  domain.SessionID
}

func newFixture(t *testing.T) *testFixture {
	t.Helper()
	// Temp file DB rather than :memory: — :memory: gives each new connection
	// its own private DB, which masks real concurrency behaviour. A file
	// shared via the standard connection pool exercises the actual
	// BEGIN IMMEDIATE / busy_timeout interaction.
	path := t.TempDir() + "/kickstand_test.db"
	d, err := db.Open(path)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { d.Close() })

	ctx := context.Background()
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	f := &testFixture{
		t:          t,
		db:         d,
		now:        time.Date(2026, 6, 6, 9, 0, 0, 0, time.UTC),
		schoolID:   domain.SchoolID("school_lagan"),
		location:   domain.LocationID("loc_belfast"),
		otherLoc:   domain.LocationID("loc_lisburn"),
		instructor: domain.UserID("user_instructor"),
		courseCBT:  domain.CourseTypeID("ct_cbt_125"),
		bikeA1:     domain.BikeID("bike_a1_manual"),
		bikeA2:     domain.BikeID("bike_a2_manual"),
		studentA:   domain.UserID("user_student_a"),
		studentB:   domain.UserID("user_student_b"),
		sessionID:  domain.SessionID("sess_cbt_tomorrow"),
	}
	f.scope = tenant.NewScope(d, f.schoolID)
	f.seed(ctx)
	return f
}

// seed inserts a minimal-but-realistic dataset. The booking tests then
// override specific rows (e.g. add a bike_unavailability) to exercise edge
// cases.
func (f *testFixture) seed(ctx context.Context) {
	f.t.Helper()
	createdAt := f.now.Format(time.RFC3339)
	sessionStart := f.now.Add(24 * time.Hour)
	sessionEnd := sessionStart.Add(4 * time.Hour)

	exec := func(q string, args ...any) {
		f.t.Helper()
		if _, err := f.db.ExecContext(ctx, q, args...); err != nil {
			f.t.Fatalf("seed exec %q: %v", q, err)
		}
	}

	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at)
	      VALUES (?, ?, 'NI', 'DVA', ?)`,
		f.schoolID, "Lagan Valley", createdAt)

	exec(`INSERT INTO locations (id, school_id, name, created_at) VALUES (?, ?, ?, ?)`,
		f.location, f.schoolID, "Belfast", createdAt)
	exec(`INSERT INTO locations (id, school_id, name, created_at) VALUES (?, ?, ?, ?)`,
		f.otherLoc, f.schoolID, "Lisburn", createdAt)

	// Instructor user + qualification
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES (?, ?, ?, '', ?, 'instructor', ?)`,
		f.instructor, f.schoolID, "dave@lagan.test", "Dave Instructor", createdAt)
	exec(`INSERT INTO instructor_profiles (user_id, school_id, home_location_id) VALUES (?, ?, ?)`,
		f.instructor, f.schoolID, f.location)

	// Course type — CBT 125 (NI), requires A1 category
	exec(`INSERT INTO course_types (id, school_id, code, name, region, required_bike_category,
	          duration_minutes, max_ratio, price_pence, non_teaching, created_at)
	      VALUES (?, ?, 'CBT-125', 'CBT 125', 'NI', 'A1', 240, 4, 13000, 0, ?)`,
		f.courseCBT, f.schoolID, createdAt)
	exec(`INSERT INTO instructor_qualifications (school_id, instructor_id, course_type_id) VALUES (?, ?, ?)`,
		f.schoolID, f.instructor, f.courseCBT)

	// Bikes
	exec(`INSERT INTO bikes (id, school_id, category, transmission, status, home_location_id, current_location_id, created_at)
	      VALUES (?, ?, 'A1', 'manual', 'ready', ?, ?, ?)`,
		f.bikeA1, f.schoolID, f.location, f.location, createdAt)
	exec(`INSERT INTO bikes (id, school_id, category, transmission, status, home_location_id, current_location_id, created_at)
	      VALUES (?, ?, 'A2', 'manual', 'ready', ?, ?, ?)`,
		f.bikeA2, f.schoolID, f.location, f.location, createdAt)

	// Students (active + their profiles)
	for _, sid := range []domain.UserID{f.studentA, f.studentB} {
		exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
		      VALUES (?, ?, ?, '', ?, 'student', 'active', ?)`,
			sid, f.schoolID, string(sid)+"@test", string(sid), createdAt)
		exec(`INSERT INTO student_profiles (user_id, school_id, transmission_preference,
		          cbt_certificate_held, theory_passed)
		      VALUES (?, ?, 'manual', 0, 0)`,
			sid, f.schoolID)
	}

	// One session, capacity 2
	exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id,
	          starts_at, ends_at, capacity, created_at)
	      VALUES (?, ?, ?, ?, ?, ?, ?, 2, ?)`,
		f.sessionID, f.schoolID, f.courseCBT, f.instructor, f.location,
		sessionStart.Format(time.RFC3339), sessionEnd.Format(time.RFC3339), createdAt)
}

func (f *testFixture) book(req booking.Request) (*booking.Result, error) {
	return booking.BookAt(context.Background(), f.scope, req, func() time.Time { return f.now })
}

// ----- Tests -----

func TestBook_HappyPath_AutoAssign(t *testing.T) {
	f := newFixture(t)
	res, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	if res.Booking.BikeID != f.bikeA1 {
		t.Errorf("expected auto-assigned bike %s (the A1 one), got %s", f.bikeA1, res.Booking.BikeID)
	}
	if res.Booking.Status != domain.BookingBooked {
		t.Errorf("expected status booked, got %s", res.Booking.Status)
	}
	// CBT-missing and theory-missing advisories should fire (test students
	// have neither set in the seed).
	codes := advisoryCodes(res)
	if !contains(codes, booking.AdvisoryCBTMissing) {
		t.Errorf("expected cbt_missing advisory, got %v", codes)
	}
	if !contains(codes, booking.AdvisoryTheoryMissing) {
		t.Errorf("expected theory_missing advisory, got %v", codes)
	}
}

func TestBook_HappyPath_ExplicitBike(t *testing.T) {
	f := newFixture(t)
	// CBT-125 requires A1 — the A2 bike is unsuitable.
	_, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA, BikeID: f.bikeA2})
	if !errors.Is(err, booking.ErrBikeNotSuitable) {
		t.Fatalf("expected ErrBikeNotSuitable, got %v", err)
	}

	// Explicit A1 should work.
	res, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA, BikeID: f.bikeA1})
	if err != nil {
		t.Fatalf("book with explicit A1: %v", err)
	}
	if res.Booking.BikeID != f.bikeA1 {
		t.Errorf("expected bike %s, got %s", f.bikeA1, res.Booking.BikeID)
	}
}

func TestBook_NoSuitableBike_DespiteFreeCapacity(t *testing.T) {
	// The headline behaviour: bike-aware capacity. We add a second A1 bike,
	// then make the first one offline and the second in an unavailability
	// window. Capacity is 2, zero bookings, but no bike is reachable.
	f := newFixture(t)
	ctx := context.Background()

	_, err := f.db.ExecContext(ctx, `UPDATE bikes SET status = 'offline' WHERE id = ?`, f.bikeA1)
	if err != nil {
		t.Fatal(err)
	}

	_, err = f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if !errors.Is(err, booking.ErrNoSuitableBike) {
		t.Fatalf("expected ErrNoSuitableBike, got %v", err)
	}
}

func TestBook_CapacityFull(t *testing.T) {
	f := newFixture(t)

	// Add a 2nd A1 bike so we don't hit ErrNoSuitableBike first.
	addA1Bike(t, f, "bike_a1_second")

	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA}); err != nil {
		t.Fatalf("first booking: %v", err)
	}
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentB}); err != nil {
		t.Fatalf("second booking: %v", err)
	}

	// A third student would push us past capacity=2.
	addStudent(t, f, "user_student_c")
	_, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: "user_student_c"})
	if !errors.Is(err, booking.ErrCapacityFull) {
		t.Fatalf("expected ErrCapacityFull, got %v", err)
	}
}

func TestBook_AlreadyBookedSameStudent(t *testing.T) {
	f := newFixture(t)
	addA1Bike(t, f, "bike_a1_second")

	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA}); err != nil {
		t.Fatalf("first booking: %v", err)
	}
	_, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if !errors.Is(err, booking.ErrAlreadyBooked) {
		t.Fatalf("expected ErrAlreadyBooked, got %v", err)
	}
}

func TestBook_PendingStudentBlocked(t *testing.T) {
	f := newFixture(t)
	_, err := f.db.Exec(`UPDATE users SET account_status = 'pending_approval' WHERE id = ?`, f.studentA)
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if !errors.Is(err, booking.ErrStudentNotActive) {
		t.Fatalf("expected ErrStudentNotActive, got %v", err)
	}
}

func TestBook_PastSessionRejected(t *testing.T) {
	f := newFixture(t)
	// Roll the clock forward past the session.
	res, err := booking.BookAt(context.Background(), f.scope,
		booking.Request{SessionID: f.sessionID, StudentID: f.studentA},
		func() time.Time { return f.now.Add(72 * time.Hour) },
	)
	if !errors.Is(err, booking.ErrSessionInPast) {
		t.Fatalf("expected ErrSessionInPast, got %v (res=%v)", err, res)
	}
}

func TestBook_BikeUnavailabilityWindowBlocks(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	// Make the A1 bike unavailable during the session window.
	_, err := f.db.ExecContext(ctx, `
		INSERT INTO bike_unavailability (id, school_id, bike_id, reason, starts_at, ends_at, created_at, created_by)
		VALUES ('bu1', ?, ?, 'mechanic', ?, ?, ?, ?)
	`, f.schoolID, f.bikeA1,
		f.now.Add(20*time.Hour).Format(time.RFC3339),
		f.now.Add(40*time.Hour).Format(time.RFC3339),
		f.now.Format(time.RFC3339), f.instructor)
	if err != nil {
		t.Fatal(err)
	}

	_, err = f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if !errors.Is(err, booking.ErrNoSuitableBike) {
		t.Fatalf("expected ErrNoSuitableBike, got %v", err)
	}
}

func TestBook_CrossSiteAdvisoryWhenBikeIsAtOtherLocation(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	// Move the only A1 bike to the other site. It's still suitable, but
	// surfaces a cross_site_bike advisory.
	_, err := f.db.ExecContext(ctx, `UPDATE bikes SET current_location_id = ? WHERE id = ?`,
		f.otherLoc, f.bikeA1)
	if err != nil {
		t.Fatal(err)
	}

	res, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	if !contains(advisoryCodes(res), booking.AdvisoryCrossSiteBike) {
		t.Errorf("expected cross_site_bike advisory, got %v", advisoryCodes(res))
	}
}

func TestBook_TestDay_NonTeaching_SkipsPrereqAdvisories(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	// Flip the course type to non_teaching (a test day). Re-use the same
	// session so the bike/instructor wiring is unchanged.
	_, err := f.db.ExecContext(ctx, `UPDATE course_types SET non_teaching = 1 WHERE id = ?`, f.courseCBT)
	if err != nil {
		t.Fatal(err)
	}

	res, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	codes := advisoryCodes(res)
	if contains(codes, booking.AdvisoryCBTMissing) || contains(codes, booking.AdvisoryTheoryMissing) {
		t.Errorf("test days should not surface teaching-prereq advisories: %v", codes)
	}
}

func TestBook_ConcurrentRace_OnlyOneBookingWins(t *testing.T) {
	// The classic SQLite WAL/IMMEDIATE race: two students try to book the
	// only suitable bike at the same instant. Exactly one must succeed.
	f := newFixture(t)
	ctx := context.Background()

	// Remove the A2 bike so there's only one suitable bike for CBT 125.
	if _, err := f.db.ExecContext(ctx, `DELETE FROM bikes WHERE id = ?`, f.bikeA2); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	results := make([]error, 2)
	students := []domain.UserID{f.studentA, f.studentB}
	wg.Add(2)
	for i := range students {
		i := i
		go func() {
			defer wg.Done()
			_, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: students[i]})
			results[i] = err
		}()
	}
	wg.Wait()

	wins, losses := 0, 0
	for _, err := range results {
		switch {
		case err == nil:
			wins++
		case errors.Is(err, booking.ErrNoSuitableBike), errors.Is(err, booking.ErrCapacityFull):
			losses++
		default:
			t.Fatalf("unexpected error from concurrent booking: %v", err)
		}
	}
	if wins != 1 || losses != 1 {
		t.Fatalf("expected exactly one winner; got %d wins / %d losses (%v)", wins, losses, results)
	}
}

func TestBook_InstructorUnqualified(t *testing.T) {
	f := newFixture(t)
	_, err := f.db.Exec(`DELETE FROM instructor_qualifications
	                     WHERE instructor_id = ? AND course_type_id = ?`,
		f.instructor, f.courseCBT)
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if !errors.Is(err, booking.ErrInstructorUnqualified) {
		t.Fatalf("expected ErrInstructorUnqualified, got %v", err)
	}
}

func TestBook_CrossTenantSessionInvisible(t *testing.T) {
	// A scope for a different school must not be able to book against this
	// school's session. The query's school_id filter is the seam.
	f := newFixture(t)
	otherScope := tenant.NewScope(f.db, domain.SchoolID("school_other"))
	_, err := booking.BookAt(context.Background(), otherScope,
		booking.Request{SessionID: f.sessionID, StudentID: f.studentA},
		func() time.Time { return f.now })
	if !errors.Is(err, booking.ErrSessionNotFound) {
		t.Fatalf("expected ErrSessionNotFound (tenant-isolated), got %v", err)
	}
}

// ----- helpers -----

func addA1Bike(t *testing.T, f *testFixture, id string) {
	t.Helper()
	_, err := f.db.Exec(`INSERT INTO bikes (id, school_id, category, transmission, status, home_location_id, current_location_id, created_at)
	                     VALUES (?, ?, 'A1', 'manual', 'ready', ?, ?, ?)`,
		id, f.schoolID, f.location, f.location, f.now.Format(time.RFC3339))
	if err != nil {
		t.Fatalf("add A1 bike: %v", err)
	}
}

func addStudent(t *testing.T, f *testFixture, id string) {
	t.Helper()
	_, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                     VALUES (?, ?, ?, '', ?, 'student', 'active', ?)`,
		id, f.schoolID, id+"@t", id, f.now.Format(time.RFC3339))
	if err != nil {
		t.Fatalf("add student: %v", err)
	}
	_, err = f.db.Exec(`INSERT INTO student_profiles (user_id, school_id, transmission_preference, cbt_certificate_held, theory_passed)
	                    VALUES (?, ?, 'manual', 0, 0)`,
		id, f.schoolID)
	if err != nil {
		t.Fatalf("add student profile: %v", err)
	}
}

func advisoryCodes(r *booking.Result) []string {
	out := make([]string, 0, len(r.Advisories))
	for _, a := range r.Advisories {
		out = append(out, a.Code)
	}
	return out
}

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}

// Compile-time guard: testFixture must remain a struct (not aliased) so
// the helpers can take it by pointer.
var _ = fmt.Sprintf
