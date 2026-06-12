package booking_test

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

func TestWaitlist_JoinRequiresFullSession(t *testing.T) {
	f := newFixture(t)
	// Seeded session capacity = 2, zero bookings — joining the waitlist
	// must be refused because the student should just book.
	_, err := booking.JoinWaitlistAt(context.Background(), f.scope,
		f.sessionID, f.studentA, func() time.Time { return f.now })
	if !errors.Is(err, booking.ErrWaitlistNotApplicable) {
		t.Fatalf("expected ErrWaitlistNotApplicable, got %v", err)
	}
}

func TestWaitlist_PromotesOnCancel(t *testing.T) {
	f := newFixture(t)
	// The seed has one A1 bike; capacity 2 needs two. Add a second.
	addA1Bike(t, f, "bike_a1_second")
	// Add a third student so we have an extra waiter.
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                       VALUES ('user_stu_c', ?, ?, '', 'Student C', 'student', 'active', ?)`,
		f.schoolID, "user_stu_c@test", f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO student_profiles (user_id, school_id, transmission_preference, cbt_certificate_held, theory_passed)
	                       VALUES ('user_stu_c', ?, 'manual', 0, 0)`, f.schoolID); err != nil {
		t.Fatal(err)
	}

	// Fill the 2-capacity session with A and B.
	res1, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book A: %v", err)
	}
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentB}); err != nil {
		t.Fatalf("book B: %v", err)
	}

	// C tries to book → capacity_full. Then joins the waitlist.
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: "user_stu_c"}); !errors.Is(err, booking.ErrCapacityFull) {
		t.Fatalf("expected ErrCapacityFull for C, got %v", err)
	}
	entry, err := booking.JoinWaitlistAt(context.Background(), f.scope,
		f.sessionID, "user_stu_c", func() time.Time { return f.now })
	if err != nil {
		t.Fatalf("join waitlist: %v", err)
	}
	if entry.ID == "" {
		t.Error("expected non-empty waitlist id")
	}

	// A cancels → C should be auto-promoted.
	if _, err := booking.CancelAt(context.Background(), f.scope, booking.CancelRequest{
		BookingID:         res1.Booking.ID,
		CancelledBy:       domain.CancelledByStudent,
		ExpectedStudentID: f.studentA,
	}, func() time.Time { return f.now }); err != nil {
		t.Fatalf("cancel: %v", err)
	}

	// C now has an active booking on the session.
	var cBookingCount int
	if err := f.db.QueryRow(`
		SELECT COUNT(*) FROM bookings
		WHERE school_id = ? AND session_id = ? AND student_id = 'user_stu_c'
		  AND status = 'booked'
	`, f.schoolID, f.sessionID).Scan(&cBookingCount); err != nil {
		t.Fatal(err)
	}
	if cBookingCount != 1 {
		t.Errorf("expected C to be booked after auto-promotion, got %d bookings", cBookingCount)
	}

	// Waitlist row marked promoted with the new booking ID.
	var promotedAt, promotedBookingID sql.NullString
	if err := f.db.QueryRow(`
		SELECT promoted_at, promoted_booking_id FROM waitlist_entries
		WHERE school_id = ? AND session_id = ? AND student_id = 'user_stu_c'
	`, f.schoolID, f.sessionID).Scan(&promotedAt, &promotedBookingID); err != nil {
		t.Fatal(err)
	}
	if !promotedAt.Valid || promotedAt.String == "" {
		t.Error("expected promoted_at to be set")
	}
	if !promotedBookingID.Valid || promotedBookingID.String == "" {
		t.Error("expected promoted_booking_id to be set")
	}

	// A waitlist.promoted event + an in-app notification for C should
	// have fired in the same tx as the new booking.
	var eventCount, notifyCount int
	if err := f.db.QueryRow(
		`SELECT COUNT(*) FROM events WHERE school_id = ? AND kind = 'waitlist.promoted'`,
		f.schoolID).Scan(&eventCount); err != nil {
		t.Fatal(err)
	}
	if eventCount != 1 {
		t.Errorf("expected 1 waitlist.promoted event, got %d", eventCount)
	}
	if err := f.db.QueryRow(`
		SELECT COUNT(*) FROM notifications n
		JOIN events e ON e.id = n.event_id
		WHERE n.school_id = ? AND e.kind = 'waitlist.promoted'
		  AND n.recipient_id = 'user_stu_c'
	`, f.schoolID).Scan(&notifyCount); err != nil {
		t.Fatal(err)
	}
	if notifyCount != 1 {
		t.Errorf("expected 1 notification for C, got %d", notifyCount)
	}
}

func TestWaitlist_DuplicateJoinRejected(t *testing.T) {
	f := newFixture(t)
	addA1Bike(t, f, "bike_a1_second")
	// Fill the session.
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentB}); err != nil {
		t.Fatal(err)
	}
	// Add another student for waiting.
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                       VALUES ('user_stu_d', ?, ?, '', 'D', 'student', 'active', ?)`,
		f.schoolID, "d@t", f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO student_profiles (user_id, school_id, cbt_certificate_held, theory_passed)
	                       VALUES ('user_stu_d', ?, 0, 0)`, f.schoolID); err != nil {
		t.Fatal(err)
	}

	clock := func() time.Time { return f.now }
	if _, err := booking.JoinWaitlistAt(context.Background(), f.scope, f.sessionID, "user_stu_d", clock); err != nil {
		t.Fatalf("first join: %v", err)
	}
	if _, err := booking.JoinWaitlistAt(context.Background(), f.scope, f.sessionID, "user_stu_d", clock); !errors.Is(err, booking.ErrAlreadyOnWaitlist) {
		t.Fatalf("expected ErrAlreadyOnWaitlist, got %v", err)
	}
}
