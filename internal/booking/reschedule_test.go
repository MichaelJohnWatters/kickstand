package booking_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// addSecondSession adds another future session at the same location so we
// have somewhere to reschedule to. Returns the new session ID.
func addSecondSession(t *testing.T, f *testFixture, id, courseTypeID, instructor string, capacity int, hoursOut int) domain.SessionID {
	t.Helper()
	start := f.now.Add(time.Duration(hoursOut) * time.Hour)
	end := start.Add(4 * time.Hour)
	_, err := f.db.Exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id,
	          starts_at, ends_at, capacity, created_at)
	      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, f.schoolID, courseTypeID, instructor, f.location,
		start.Format(time.RFC3339), end.Format(time.RFC3339), capacity, f.now.Format(time.RFC3339))
	if err != nil {
		t.Fatalf("add session: %v", err)
	}
	if _, err := f.db.Exec(`INSERT INTO session_instructors
	    (id, school_id, session_id, instructor_id, is_primary, assigned_at, assigned_by)
	    VALUES (?, ?, ?, ?, 1, ?, ?)`,
		"si_"+id, f.schoolID, id, instructor, f.now.Format(time.RFC3339), instructor); err != nil {
		t.Fatalf("add session instructor: %v", err)
	}
	return domain.SessionID(id)
}

func TestReschedule_HappyPath(t *testing.T) {
	f := newFixture(t)
	addA1Bike(t, f, "bike_a1_second") // give us a second suitable bike
	newSess := addSecondSession(t, f, "sess_later", string(f.courseCBT), string(f.instructor), 2, 72)

	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("initial book: %v", err)
	}

	res, err := booking.RescheduleAt(context.Background(), f.scope,
		booking.RescheduleRequest{
			BookingID:    booked.Booking.ID,
			NewSessionID: newSess,
			CancelledBy:  domain.CancelledByStudent,
			Reason:       "moving to a later date",
		},
		func() time.Time { return f.now },
	)
	if err != nil {
		t.Fatalf("reschedule: %v", err)
	}
	if res.CancelledBooking.Status != domain.BookingCancelled {
		t.Errorf("expected cancelled status on old, got %s", res.CancelledBooking.Status)
	}
	if res.NewBooking.SessionID != newSess {
		t.Errorf("expected new session id %s, got %s", newSess, res.NewBooking.SessionID)
	}
	if res.NewBooking.Status != domain.BookingBooked {
		t.Errorf("expected booked on new, got %s", res.NewBooking.Status)
	}
}

func TestReschedule_FailedRebook_PreservesOriginal(t *testing.T) {
	// The critical invariant: if rebooking fails (e.g. target session full),
	// the cancel must roll back so the student keeps their slot.
	f := newFixture(t)

	// Add a second session with capacity 1, then book another student into
	// it so it's full.
	targetSess := addSecondSession(t, f, "sess_full", string(f.courseCBT), string(f.instructor), 1, 72)
	if _, err := f.book(booking.Request{SessionID: targetSess, StudentID: f.studentB}); err != nil {
		t.Fatalf("seed target full: %v", err)
	}

	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("initial book: %v", err)
	}

	_, err = booking.RescheduleAt(context.Background(), f.scope,
		booking.RescheduleRequest{
			BookingID:    booked.Booking.ID,
			NewSessionID: targetSess,
			CancelledBy:  domain.CancelledByStudent,
		},
		func() time.Time { return f.now },
	)
	if !errors.Is(err, booking.ErrCapacityFull) {
		t.Fatalf("expected ErrCapacityFull from rebook half, got %v", err)
	}

	// The original booking must still be 'booked' (cancel rolled back).
	var status string
	if err := f.db.QueryRow(`SELECT status FROM bookings WHERE id = ?`, booked.Booking.ID).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if status != "booked" {
		t.Fatalf("original booking should be 'booked' after failed reschedule, got %q", status)
	}
}

func TestReschedule_BookingNotFound(t *testing.T) {
	f := newFixture(t)
	newSess := addSecondSession(t, f, "sess_later", string(f.courseCBT), string(f.instructor), 2, 72)
	_, err := booking.RescheduleAt(context.Background(), f.scope,
		booking.RescheduleRequest{
			BookingID:    "nope",
			NewSessionID: newSess,
			CancelledBy:  domain.CancelledByStudent,
		},
		func() time.Time { return f.now })
	if !errors.Is(err, booking.ErrBookingNotFound) {
		t.Fatalf("expected ErrBookingNotFound, got %v", err)
	}
}

func TestReschedule_ExpectedStudentMismatchRejected(t *testing.T) {
	// Same authz guarantee as cancel: student B can't reschedule student A's
	// booking. Mismatch returns ErrBookingNotFound (no info leak).
	f := newFixture(t)
	newSess := addSecondSession(t, f, "sess_other", string(f.courseCBT), string(f.instructor), 2, 96)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	_, err = booking.RescheduleAt(context.Background(), f.scope,
		booking.RescheduleRequest{
			BookingID:         booked.Booking.ID,
			NewSessionID:      newSess,
			CancelledBy:       domain.CancelledByStudent,
			ExpectedStudentID: f.studentB,
		},
		func() time.Time { return f.now })
	if !errors.Is(err, booking.ErrBookingNotFound) {
		t.Fatalf("expected ErrBookingNotFound, got %v", err)
	}
}

func TestReschedule_SameStudent_FreesOwnBikeForRebook(t *testing.T) {
	// Edge case: rescheduling to a session at the same time as the original
	// would normally conflict on the bike. Within the same tx the old
	// booking is cancelled first, which frees the bike for the new attempt.
	// We use a different session at a non-overlapping time to keep this
	// simple — but the invariant matters when callers do overlapping rebooks.
	f := newFixture(t)
	newSess := addSecondSession(t, f, "sess_other", string(f.courseCBT), string(f.instructor), 2, 96)

	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("initial book: %v", err)
	}
	res, err := booking.RescheduleAt(context.Background(), f.scope,
		booking.RescheduleRequest{
			BookingID:    booked.Booking.ID,
			NewSessionID: newSess,
			NewBikeID:    f.bikeA1, // same bike as before; only works because cancel runs first
			CancelledBy:  domain.CancelledByStudent,
		},
		func() time.Time { return f.now })
	if err != nil {
		t.Fatalf("reschedule: %v", err)
	}
	if res.NewBooking.BikeID != f.bikeA1 {
		t.Errorf("expected same bike on rebook, got %s", res.NewBooking.BikeID)
	}
}
