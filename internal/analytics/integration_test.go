package analytics_test

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/analytics"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// fixture spins up a minimal analytics test scenario: 1 school, 2
// instructors, 2 students, 2 bikes, 1 CBT course type, 2 sessions
// (one in window with bookings, one out of window), plus an
// instructor earning, a payment, an external test, and a signup
// inside the window so the funnel has signal.
type fixture struct {
	t         *testing.T
	db        *sql.DB
	scope     *tenant.Scope
	schoolID  domain.SchoolID
	window    analytics.Window
	instrDave domain.UserID
	bikeA1    domain.BikeID
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	path := t.TempDir() + "/analytics_test.db"
	d, err := db.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	ctx := context.Background()
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	now := time.Date(2026, 6, 12, 12, 0, 0, 0, time.UTC)
	from := now.AddDate(0, 0, -30)
	to := now

	f := &fixture{
		t:         t,
		db:        d,
		schoolID:  domain.SchoolID("school_lagan"),
		window:    analytics.Window{From: from, To: to},
		instrDave: domain.UserID("user_instr_dave"),
		bikeA1:    domain.BikeID("bike_a1"),
	}
	f.scope = tenant.NewScope(d, f.schoolID)
	f.seed(ctx, now)
	return f
}

func (f *fixture) seed(ctx context.Context, now time.Time) {
	f.t.Helper()
	exec := func(q string, args ...any) {
		f.t.Helper()
		if _, err := f.db.ExecContext(ctx, q, args...); err != nil {
			f.t.Fatalf("seed: %v\nq: %s", err, q)
		}
	}

	createdAt := now.AddDate(0, -2, 0).Format(time.RFC3339)
	signupInWindow := now.AddDate(0, 0, -10).Format(time.RFC3339)
	inWindowSession := now.AddDate(0, 0, -5)
	outOfWindowSession := now.AddDate(0, 0, -45)

	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at)
	      VALUES (?, 'Lagan', 'NI', 'DVA', ?)`, f.schoolID, createdAt)
	exec(`INSERT INTO locations (id, school_id, name, created_at)
	      VALUES ('loc_belfast', ?, 'Belfast', ?)`, f.schoolID, createdAt)

	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES (?, ?, 'dave@l.test', '', 'Dave', 'instructor', ?)`,
		f.instrDave, f.schoolID, createdAt)
	exec(`INSERT INTO instructor_profiles (user_id, school_id, home_location_id)
	      VALUES (?, ?, 'loc_belfast')`, f.instrDave, f.schoolID)

	// Two students: one signed up before the window (no funnel weight),
	// one signed up inside the window (funnel sample = 1).
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES ('user_stu_alex', ?, 'alex@t.test', '', 'Alex', 'student', 'active', ?)`,
		f.schoolID, createdAt)
	exec(`INSERT INTO student_profiles (user_id, school_id, transmission_preference, cbt_certificate_held, theory_passed)
	      VALUES ('user_stu_alex', ?, 'manual', 0, 0)`, f.schoolID)
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES ('user_stu_maeve', ?, 'maeve@t.test', '', 'Maeve', 'student', 'active', ?)`,
		f.schoolID, signupInWindow)
	exec(`INSERT INTO student_profiles (user_id, school_id, transmission_preference, cbt_certificate_held, theory_passed)
	      VALUES ('user_stu_maeve', ?, 'manual', 0, 0)`, f.schoolID)

	// CBT course type — CBT prefix is matched by the funnel.
	exec(`INSERT INTO course_types (id, school_id, code, name, region, required_bike_category,
	          duration_minutes, max_ratio, price_pence, non_teaching, created_at)
	      VALUES ('ct_cbt_125', ?, 'CBT-125', 'CBT 125', 'NI', 'A1', 240, 4, 13000, 0, ?)`,
		f.schoolID, createdAt)
	exec(`INSERT INTO instructor_accreditations (school_id, instructor_id, course_type_id)
	      VALUES (?, ?, 'ct_cbt_125')`, f.schoolID, f.instrDave)

	// Bike
	exec(`INSERT INTO bikes (id, school_id, nickname, registration, category, transmission, status,
	          home_location_id, current_location_id, created_at)
	      VALUES (?, ?, 'Test Honda', 'GKZ 0001', 'A1', 'manual', 'ready',
	              'loc_belfast', 'loc_belfast', ?)`,
		f.bikeA1, f.schoolID, createdAt)

	// In-window session — 4 hours, with a completed booking for Alex
	// on the bike. Counts toward bike util + instructor util + CBT
	// completion.
	exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id,
	          starts_at, ends_at, capacity, status, created_at)
	      VALUES ('sess_in', ?, 'ct_cbt_125', ?, 'loc_belfast', ?, ?, 2, 'scheduled', ?)`,
		f.schoolID, f.instrDave,
		inWindowSession.Format(time.RFC3339),
		inWindowSession.Add(4*time.Hour).Format(time.RFC3339),
		createdAt)
	exec(`INSERT INTO bookings (id, school_id, session_id, student_id, bike_id, status, created_at)
	      VALUES ('bk_in', ?, 'sess_in', 'user_stu_alex', ?, 'completed', ?)`,
		f.schoolID, f.bikeA1, createdAt)
	// Booking conversion attribution: Maeve signed up in-window and
	// booked promptly — funnel signup→first-booking = 100%.
	exec(`INSERT INTO bookings (id, school_id, session_id, student_id, bike_id, status, created_at)
	      VALUES ('bk_in2', ?, 'sess_in', 'user_stu_maeve', ?, 'booked', ?)`,
		f.schoolID, f.bikeA1,
		// Booking created after Maeve signed up but within 30 days.
		now.AddDate(0, 0, -9).Format(time.RFC3339))

	// Out-of-window session — same bike, must not count toward utilisation
	// or instructor-hours in the report.
	exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id,
	          starts_at, ends_at, capacity, status, created_at)
	      VALUES ('sess_out', ?, 'ct_cbt_125', ?, 'loc_belfast', ?, ?, 2, 'scheduled', ?)`,
		f.schoolID, f.instrDave,
		outOfWindowSession.Format(time.RFC3339),
		outOfWindowSession.Add(4*time.Hour).Format(time.RFC3339),
		createdAt)

	// Instructor earning + payment, both inside the window.
	exec(`INSERT INTO instructor_pay_models (id, school_id, instructor_id, pay_basis, rate_value, created_at)
	      VALUES ('pm_dave', ?, ?, 'per_session', 7500, ?)`,
		f.schoolID, f.instrDave, createdAt)
	exec(`INSERT INTO instructor_earnings (id, school_id, instructor_id, session_id, amount_pence, basis, created_at, created_by)
	      VALUES ('ee_1', ?, ?, 'sess_in', 7500, 'per_session', ?, ?)`,
		f.schoolID, f.instrDave, now.AddDate(0, 0, -3).Format(time.RFC3339), f.instrDave)
	exec(`INSERT INTO instructor_payments (id, school_id, instructor_id, amount_pence, method, paid_at, recorded_by)
	      VALUES ('pp_1', ?, ?, 3000, 'bank_transfer', ?, ?)`,
		f.schoolID, f.instrDave, now.AddDate(0, 0, -2).Format(time.RFC3339), f.instrDave)

	// External test — theory pass inside the window.
	exec(`INSERT INTO external_tests (id, school_id, student_id, test_type, region, outcome, created_at)
	      VALUES ('et_1', ?, 'user_stu_alex', 'theory', 'NI', 'pass', ?)`,
		f.schoolID, now.AddDate(0, 0, -2).Format(time.RFC3339))
}

func TestBikeUtilisation_IncludesInWindowExcludesOut(t *testing.T) {
	f := newFixture(t)
	rows, err := analytics.BikeUtilisation(context.Background(), f.scope, f.window)
	if err != nil {
		t.Fatalf("BikeUtilisation: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 bike, got %d", len(rows))
	}
	got := rows[0]
	if got.SessionsCount != 1 {
		t.Errorf("expected 1 session counted, got %d (out-of-window session leaked in?)", got.SessionsCount)
	}
	// 4-hour session = 240 minutes.
	if got.BookedMinutes != 240 {
		t.Errorf("expected 240 booked minutes, got %d", got.BookedMinutes)
	}
	if got.UtilisationPct <= 0 {
		t.Errorf("expected positive utilisation pct, got %.2f", got.UtilisationPct)
	}
}

func TestInstructorUtilisation_TallieEarningsAndOutstanding(t *testing.T) {
	f := newFixture(t)
	rows, err := analytics.InstructorUtilisation(context.Background(), f.scope, f.window)
	if err != nil {
		t.Fatalf("InstructorUtilisation: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 instructor, got %d", len(rows))
	}
	got := rows[0]
	if got.SessionsTaught != 1 {
		t.Errorf("expected 1 session taught, got %d", got.SessionsTaught)
	}
	if got.EarnedPence != 7500 {
		t.Errorf("expected 7500p earned, got %d", got.EarnedPence)
	}
	if got.PaidPence != 3000 {
		t.Errorf("expected 3000p paid, got %d", got.PaidPence)
	}
	if got.OutstandingPence != 4500 {
		t.Errorf("expected 4500p outstanding, got %d", got.OutstandingPence)
	}
	if len(got.WeeklyTrend) != 8 {
		t.Errorf("expected 8-bucket weekly trend, got %d buckets", len(got.WeeklyTrend))
	}
}

func TestFunnel_BasicShape(t *testing.T) {
	f := newFixture(t)
	fs, err := analytics.Funnel(context.Background(), f.scope, f.window)
	if err != nil {
		t.Fatalf("Funnel: %v", err)
	}
	if fs.SignupSample != 1 {
		t.Errorf("expected 1 in-window signup (Maeve), got %d", fs.SignupSample)
	}
	if fs.SignupToFirstBookingPct != 100 {
		t.Errorf("expected Maeve to have booked within 30d, got pct=%.2f", fs.SignupToFirstBookingPct)
	}
	if fs.CBTSample < 2 {
		t.Errorf("expected at least 2 CBT bookings in window, got %d", fs.CBTSample)
	}
	if fs.TheorySample != 1 {
		t.Errorf("expected 1 theory test sample, got %d", fs.TheorySample)
	}
	if fs.TheoryPassPct != 100 {
		t.Errorf("expected 100%% theory pass rate, got %.2f", fs.TheoryPassPct)
	}
	if len(fs.PerInstructorPassRate) != 1 {
		t.Errorf("expected 1 instructor pass-rate row, got %d", len(fs.PerInstructorPassRate))
	}
}
