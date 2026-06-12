package booking_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// CancelSession is the engine behind the manager's bulk "cancel
// rainy-day sessions" workflow. We assert it:
//   - cancels every active booking on the session
//   - marks the session itself cancelled
//   - drops the waitlist
//   - is idempotent (running again is a no-op)
func TestCancelSession_CancelsBookingsAndMarksSession(t *testing.T) {
	f := newFixture(t)
	addA1Bike(t, f, "bike_a1_second")

	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA}); err != nil {
		t.Fatalf("book A: %v", err)
	}
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentB}); err != nil {
		t.Fatalf("book B: %v", err)
	}

	res, err := booking.CancelSessionAt(context.Background(), f.scope,
		f.sessionID, "Weather", func() time.Time { return f.now })
	if err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if res.BookingsCancelled != 2 {
		t.Errorf("BookingsCancelled = %d, want 2", res.BookingsCancelled)
	}

	// Session itself flipped.
	var status string
	if err := f.db.QueryRow(`SELECT status FROM sessions WHERE id = ?`, f.sessionID).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if status != "cancelled" {
		t.Errorf("session.status = %s, want cancelled", status)
	}

	// All bookings cancelled.
	var booked int
	if err := f.db.QueryRow(`
		SELECT COUNT(*) FROM bookings
		WHERE school_id = ? AND session_id = ? AND status = 'booked'
	`, f.schoolID, f.sessionID).Scan(&booked); err != nil {
		t.Fatal(err)
	}
	if booked != 0 {
		t.Errorf("expected all bookings cancelled, %d still booked", booked)
	}

	// Idempotent.
	res2, err := booking.CancelSessionAt(context.Background(), f.scope,
		f.sessionID, "Weather", func() time.Time { return f.now })
	if err != nil {
		t.Fatalf("second cancel: %v", err)
	}
	if res2.BookingsCancelled != 0 {
		t.Errorf("second cancel should be no-op, got %d", res2.BookingsCancelled)
	}
}

func TestCancelSession_DropsWaitlist(t *testing.T) {
	f := newFixture(t)
	addA1Bike(t, f, "bike_a1_second")

	// Fill capacity.
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentB}); err != nil {
		t.Fatal(err)
	}
	// Add a third student, queue them on the waitlist.
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                       VALUES ('user_stu_c', ?, 'c@t', '', 'C', 'student', 'active', ?)`,
		f.schoolID, f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO student_profiles (user_id, school_id, transmission_preference, cbt_certificate_held, theory_passed)
	                       VALUES ('user_stu_c', ?, 'manual', 0, 0)`, f.schoolID); err != nil {
		t.Fatal(err)
	}
	if _, err := booking.JoinWaitlistAt(context.Background(), f.scope, f.sessionID, "user_stu_c",
		func() time.Time { return f.now }); err != nil {
		t.Fatal(err)
	}

	res, err := booking.CancelSessionAt(context.Background(), f.scope,
		f.sessionID, "Weather", func() time.Time { return f.now })
	if err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if res.WaitlistDropped != 1 {
		t.Errorf("WaitlistDropped = %d, want 1", res.WaitlistDropped)
	}
}

func TestCancelSession_UnknownSession(t *testing.T) {
	f := newFixture(t)
	_, err := booking.CancelSessionAt(context.Background(), f.scope,
		domain.SessionID("does_not_exist"), "", func() time.Time { return f.now })
	if !errors.Is(err, booking.ErrSessionNotFound) {
		t.Fatalf("want ErrSessionNotFound, got %v", err)
	}
}
