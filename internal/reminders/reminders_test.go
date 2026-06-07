package reminders_test

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/reminders"
)

func setupFixture(t *testing.T) (*sql.DB, time.Time) {
	t.Helper()
	d, err := db.Open(t.TempDir() + "/reminders.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if err := db.Migrate(context.Background(), d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	// Use a stable "now" reference for deterministic tests.
	now := time.Date(2026, 6, 6, 10, 0, 0, 0, time.UTC)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := d.Exec(q, args...); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	exec(`INSERT INTO schools (id, name, region, test_body_label, created_at)
	      VALUES ('school_t','Test','NI','DVA',?)`, now.Format(time.RFC3339))
	exec(`INSERT INTO locations (id, school_id, name, created_at) VALUES ('loc_t','school_t','Belfast',?)`,
		now.Format(time.RFC3339))
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, created_at)
	      VALUES ('user_inst','school_t','i@t','','I','instructor',?)`, now.Format(time.RFC3339))
	exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	      VALUES ('user_stu','school_t','s@t','','S','student','active',?)`, now.Format(time.RFC3339))
	exec(`INSERT INTO course_types (id, school_id, code, name, region, required_bike_category,
	          duration_minutes, max_ratio, price_pence, non_teaching, created_at)
	      VALUES ('ct','school_t','CBT','CBT 125','NI','A1',240,4,13000,0,?)`, now.Format(time.RFC3339))
	return d, now
}

// seedSession creates a session at the given start time and returns its id.
// If `withBooking` is true, a booked row is created for the seeded student.
func seedSession(t *testing.T, d *sql.DB, now, start time.Time, id string, withBooking bool) {
	t.Helper()
	end := start.Add(4 * time.Hour)
	if _, err := d.Exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id,
	          starts_at, ends_at, capacity, created_at)
	      VALUES (?, 'school_t', 'ct', 'user_inst', 'loc_t', ?, ?, 2, ?)`,
		id, start.Format(time.RFC3339), end.Format(time.RFC3339), now.Format(time.RFC3339)); err != nil {
		t.Fatalf("seed session: %v", err)
	}
	if withBooking {
		if _, err := d.Exec(`INSERT INTO bookings (id, school_id, session_id, student_id, status, created_at)
		                    VALUES ('bk_'||?, 'school_t', ?, 'user_stu', 'booked', ?)`,
			id, id, now.Format(time.RFC3339)); err != nil {
			t.Fatalf("seed booking: %v", err)
		}
	}
}

func countNotifs(t *testing.T, d *sql.DB) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM notifications WHERE category = 'reminder'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func countEvents(t *testing.T, d *sql.DB, kind string) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM events WHERE kind = ?`, kind).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// ----- Tests -----

func TestTick_Fires24hReminder(t *testing.T) {
	d, now := setupFixture(t)
	// Session ~24h ahead exactly: should fire.
	seedSession(t, d, now, now.Add(24*time.Hour), "sess1", true)

	if err := reminders.Tick(context.Background(), d, now); err != nil {
		t.Fatalf("tick: %v", err)
	}
	if got := countEvents(t, d, "session.reminder_24h"); got != 1 {
		t.Errorf("expected 1 event, got %d", got)
	}
	if got := countNotifs(t, d); got != 1 {
		t.Errorf("expected 1 notification, got %d", got)
	}
}

func TestTick_Fires2hReminder(t *testing.T) {
	d, now := setupFixture(t)
	seedSession(t, d, now, now.Add(2*time.Hour), "sess2", true)

	if err := reminders.Tick(context.Background(), d, now); err != nil {
		t.Fatal(err)
	}
	if got := countEvents(t, d, "session.reminder_2h"); got != 1 {
		t.Errorf("expected 1 2h event, got %d", got)
	}
}

func TestTick_FiresBothHorizons(t *testing.T) {
	d, now := setupFixture(t)
	seedSession(t, d, now, now.Add(24*time.Hour), "sess_far", true)
	seedSession(t, d, now, now.Add(2*time.Hour), "sess_near", true)

	if err := reminders.Tick(context.Background(), d, now); err != nil {
		t.Fatal(err)
	}
	if got := countEvents(t, d, "session.reminder_24h"); got != 1 {
		t.Errorf("expected 1 24h event, got %d", got)
	}
	if got := countEvents(t, d, "session.reminder_2h"); got != 1 {
		t.Errorf("expected 1 2h event, got %d", got)
	}
}

func TestTick_Idempotent(t *testing.T) {
	d, now := setupFixture(t)
	seedSession(t, d, now, now.Add(24*time.Hour), "sess1", true)

	// First tick fires.
	if err := reminders.Tick(context.Background(), d, now); err != nil {
		t.Fatal(err)
	}
	first := countNotifs(t, d)
	// Second tick at the same time should NOT fire again.
	if err := reminders.Tick(context.Background(), d, now); err != nil {
		t.Fatal(err)
	}
	second := countNotifs(t, d)
	if first != second {
		t.Errorf("expected idempotency: first=%d second=%d", first, second)
	}
}

func TestTick_OutsideWindow_DoesNotFire(t *testing.T) {
	d, now := setupFixture(t)
	// Session ~6h out (between 2h and 24h horizons): should fire neither.
	seedSession(t, d, now, now.Add(6*time.Hour), "sess_mid", true)

	if err := reminders.Tick(context.Background(), d, now); err != nil {
		t.Fatal(err)
	}
	if got := countNotifs(t, d); got != 0 {
		t.Errorf("expected 0 notifications, got %d", got)
	}
}

func TestTick_OneNotificationPerBookedStudent(t *testing.T) {
	d, now := setupFixture(t)
	// Add a second active student + booking on the same session.
	if _, err := d.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                    VALUES ('user_stu2','school_t','s2@t','','S2','student','active',?)`,
		now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	seedSession(t, d, now, now.Add(24*time.Hour), "sess1", true)
	if _, err := d.Exec(`INSERT INTO bookings (id, school_id, session_id, student_id, status, created_at)
	                    VALUES ('bk_extra','school_t','sess1','user_stu2','booked',?)`,
		now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}

	if err := reminders.Tick(context.Background(), d, now); err != nil {
		t.Fatal(err)
	}
	if got := countNotifs(t, d); got != 2 {
		t.Errorf("expected 2 notifications (one per booked student), got %d", got)
	}
	// And still only one event.
	if got := countEvents(t, d, "session.reminder_24h"); got != 1 {
		t.Errorf("expected 1 event, got %d", got)
	}
}

func TestTick_SkipsCancelledBookings(t *testing.T) {
	d, now := setupFixture(t)
	seedSession(t, d, now, now.Add(24*time.Hour), "sess1", false)
	// Add a CANCELLED booking — should not get a notification.
	if _, err := d.Exec(`INSERT INTO bookings (id, school_id, session_id, student_id, status, created_at)
	                    VALUES ('bk_cancelled','school_t','sess1','user_stu','cancelled',?)`,
		now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}

	if err := reminders.Tick(context.Background(), d, now); err != nil {
		t.Fatal(err)
	}
	if got := countNotifs(t, d); got != 0 {
		t.Errorf("cancelled bookings shouldn't get reminders, got %d notifications", got)
	}
}

func TestTick_HandlesLocalTimeInput(t *testing.T) {
	// Regression: a caller passing time.Now() in a non-UTC zone must still
	// find sessions whose start times are stored as UTC `Z` strings. The
	// old code formatted local time with offset, breaking SQLite's
	// lexicographic comparison.
	d, _ := setupFixture(t)
	utcNow := time.Date(2026, 6, 6, 10, 0, 0, 0, time.UTC)
	seedSession(t, d, utcNow, utcNow.Add(24*time.Hour), "sess1", true)

	bst := time.FixedZone("BST", 3600)
	localNow := utcNow.In(bst)

	if err := reminders.Tick(context.Background(), d, localNow); err != nil {
		t.Fatal(err)
	}
	if got := countEvents(t, d, "session.reminder_24h"); got != 1 {
		t.Errorf("expected 1 event when caller passes non-UTC time, got %d", got)
	}
}

func TestTick_SkipsNonScheduledSessions(t *testing.T) {
	d, now := setupFixture(t)
	seedSession(t, d, now, now.Add(24*time.Hour), "sess_done", true)
	if _, err := d.Exec(`UPDATE sessions SET status = 'cancelled' WHERE id = 'sess_done'`); err != nil {
		t.Fatal(err)
	}
	if err := reminders.Tick(context.Background(), d, now); err != nil {
		t.Fatal(err)
	}
	if got := countNotifs(t, d); got != 0 {
		t.Errorf("expected no notifications for non-scheduled sessions, got %d", got)
	}
}
