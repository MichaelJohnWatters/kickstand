package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/filestore"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// TestSeedReplayMatches is the "would the API produce this?" gate.
//
// We seed two temp DBs side-by-side. DB A runs the full seed binary
// path — bootstrap + Direct event applier. DB B runs the same
// bootstrap but skips the Direct applier and replays the same event
// log through the *engine* path (booking.BookAt, CancelAt,
// progress.MarkAttendance). Each engine call gets the event's
// timestamp injected as the clock so "future-only" checks succeed
// even for sessions that have since become "past" by wall time.
//
// Then we diff a normalized booking view for each (student, session)
// pair the event log touched. If both paths produced equivalent state
// for those bookings, the Direct path can't fabricate a state the
// engine wouldn't reach legitimately.
//
// Scope today: just the bookings table for the two event-log
// transitions (Mark's no-show, Jordan's cancellation). Charges /
// audit_log / notifications differ between the two paths (engine
// emits them, Direct doesn't) so they're out of scope until those
// side effects also live on the event log.
func TestSeedReplayMatches(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()

	// Isolate the local filestore — both seed runs would otherwise
	// write receipt blobs into the current working directory.
	prev, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(prev) })

	// DB A — the seed binary's normal path (Direct applier).
	dsnA := filepath.Join(dir, "a.db")
	if err := run(dsnA); err != nil {
		t.Fatalf("seed A: %v", err)
	}
	dA, err := db.Open(dsnA)
	if err != nil {
		t.Fatalf("open A: %v", err)
	}
	defer dA.Close()

	// DB B — bootstrap only, then replay via Engine.
	dsnB := filepath.Join(dir, "b.db")
	dB, err := db.Open(dsnB)
	if err != nil {
		t.Fatalf("open B: %v", err)
	}
	defer dB.Close()
	if err := db.Migrate(ctx, dB); err != nil {
		t.Fatalf("migrate B: %v", err)
	}
	files, err := filestore.NewLocal(filepath.Join(dir, "uploads-b"))
	if err != nil {
		t.Fatalf("filestore B: %v", err)
	}

	// Pass an Engine applier so the seed runs the event log via real
	// API calls at the right chronological point — i.e. before the
	// disruption step that takes YBR125 offline. If we waited until
	// after the seed completed, the bike would already be offline at
	// engine-call time and Book would refuse it.
	runner := NewRunner("school_lagan")
	scope := tenant.NewScope(dB, domain.SchoolID("school_lagan"))
	applyEngine := func(events []Event, _ time.Time) error {
		return runner.ApplyEngine(ctx, scope, events)
	}
	if err := seedLaganValley(ctx, dB, nil, files, applyEngine); err != nil {
		t.Fatalf("seed B (engine applier): %v", err)
	}

	// Compare the bookings the event log touched. Identified by
	// (student, session) since engine-generated booking IDs differ
	// from the deterministic Direct IDs.
	pairs := []studentSession{
		// No-show / cancellation slice (original two)
		{"user_student_mark", "sess_today_morning"},
		{"user_student_jordan", "sess_cbt_belfast"},
		// Future bookings (tomorrow + later)
		{"user_student_maeve", "sess_practical_lisburn"},
		{"user_student_carlos", "sess_cbt_lisburn_full"},
		{"user_student_maeve", "sess_test_day_newry"},
		{"user_student_emma", "sess_cbt_lisburn_am"},
		{"user_student_jordan", "sess_prac_belfast_am"},
		{"user_student_mark", "sess_prac_belfast_pm"},
		// Today's bookings — Alex completed, Maeve booked-or-completed
		{"user_student_alex", "sess_today_morning"},
		{"user_student_maeve", "sess_today_afternoon"},
		// Past completed
		{"user_student_alex", "sess_cbt_past_belfast"},
		{"user_student_maeve", "sess_prac_past_lisburn"},
		// Past cancelled
		{"user_student_alex", "sess_cbt_past_cancelled"},
		// Active disruption: Alex needs_reassignment on YBR125 with
		// Honda as a candidate; Ryan needs_reassignment on YBR125
		// with no candidate (Honda taken by Niamh, who's on Honda
		// directly and unaffected); Niamh just booked on Honda.
		{"user_student_alex", "sess_cbt_belfast"},
		{"user_student_niamh", "sess_cbt_belfast_pm"},
		{"user_student_ryan", "sess_cbt_belfast_pm"},
		// Stale-disruption: Jordan still needs_reassignment on the
		// CB500F that came back into service a couple of days ago.
		{"user_student_jordan", "sess_stale_demo"},
		// Tight-from-prior demo: Mark on Honda CB125F for an early
		// Lisburn CBT.
		{"user_student_mark", "sess_tight_demo_prior"},
	}
	var diffs []string
	for _, p := range pairs {
		viewA, err := loadBookingView(ctx, dA, p)
		if err != nil {
			t.Fatalf("load A (%s,%s): %v", p.studentID, p.sessionID, err)
		}
		viewB, err := loadBookingView(ctx, dB, p)
		if err != nil {
			t.Fatalf("load B (%s,%s): %v", p.studentID, p.sessionID, err)
		}
		if viewA != viewB {
			diffs = append(diffs,
				fmt.Sprintf("  (%s, %s):\n      direct = %+v\n      engine = %+v",
					p.studentID, p.sessionID, viewA, viewB))
		}
	}
	if len(diffs) > 0 {
		t.Errorf("engine replay produced different state than direct seed:\n%s",
			strings.Join(diffs, "\n"))
	}
}

type studentSession struct {
	studentID string
	sessionID string
}

// bookingView is the structural slice of a booking we care about for
// equivalence: bike, status, and cancellation metadata. IDs, created_at
// and audit timestamps are deliberately excluded because they're
// generated by whichever path created the row.
type bookingView struct {
	Bike               string
	Status             string
	CancelledBy        string
	CancellationReason string
}

func loadBookingView(ctx context.Context, d *sql.DB, p studentSession) (bookingView, error) {
	var v bookingView
	err := d.QueryRowContext(ctx, `
		SELECT COALESCE(bike_id, ''), status,
		       COALESCE(cancelled_by, ''), COALESCE(cancellation_reason, '')
		FROM bookings
		WHERE student_id = ? AND session_id = ?
	`, p.studentID, p.sessionID).Scan(&v.Bike, &v.Status, &v.CancelledBy, &v.CancellationReason)
	return v, err
}
