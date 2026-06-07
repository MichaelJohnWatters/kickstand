package booking_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

func TestCancel_HappyPath_StudentOnTime(t *testing.T) {
	f := newFixture(t)

	// Book first so we have a row to cancel. The seed's session is 24h ahead;
	// the school's default cancel_cutoff_hours is 48, so a cancel "now"
	// counts as late.
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}

	res, err := booking.CancelAt(context.Background(), f.scope,
		booking.CancelRequest{
			BookingID:   booked.Booking.ID,
			CancelledBy: domain.CancelledByStudent,
			Reason:      "can't make it",
		},
		func() time.Time { return f.now },
	)
	if err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if res.Booking.Status != domain.BookingCancelled {
		t.Errorf("expected status cancelled, got %s", res.Booking.Status)
	}
	if res.Booking.CancelledBy != domain.CancelledByStudent {
		t.Errorf("cancelled_by: got %s", res.Booking.CancelledBy)
	}
	// Cutoff is 48h, session is 24h away → late.
	if !res.Late {
		t.Errorf("expected Late=true (24h to session, 48h cutoff)")
	}
}

func TestCancel_OnTime_NotLate(t *testing.T) {
	f := newFixture(t)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}

	// Push the school's cutoff down to 12h so 24h-out counts as on-time.
	if _, err := f.db.Exec(`UPDATE schools SET cancel_cutoff_hours = 12 WHERE id = ?`, f.schoolID); err != nil {
		t.Fatal(err)
	}
	res, err := booking.CancelAt(context.Background(), f.scope,
		booking.CancelRequest{BookingID: booked.Booking.ID, CancelledBy: domain.CancelledByStudent},
		func() time.Time { return f.now },
	)
	if err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if res.Late {
		t.Errorf("expected Late=false (24h to session, 12h cutoff)")
	}
}

func TestCancel_SchoolCancel(t *testing.T) {
	f := newFixture(t)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	res, err := booking.CancelAt(context.Background(), f.scope,
		booking.CancelRequest{
			BookingID:   booked.Booking.ID,
			CancelledBy: domain.CancelledBySchool,
			Reason:      "instructor off sick",
		},
		func() time.Time { return f.now },
	)
	if err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if res.Booking.CancelledBy != domain.CancelledBySchool {
		t.Errorf("cancelled_by: got %s", res.Booking.CancelledBy)
	}
	if res.Booking.CancellationReason != "instructor off sick" {
		t.Errorf("reason: got %q", res.Booking.CancellationReason)
	}
}

func TestCancel_DoubleCancelRejected(t *testing.T) {
	f := newFixture(t)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	cancel := booking.CancelRequest{BookingID: booked.Booking.ID, CancelledBy: domain.CancelledByStudent}

	if _, err := booking.CancelAt(context.Background(), f.scope, cancel, func() time.Time { return f.now }); err != nil {
		t.Fatalf("first cancel: %v", err)
	}
	_, err = booking.CancelAt(context.Background(), f.scope, cancel, func() time.Time { return f.now })
	if !errors.Is(err, booking.ErrBookingNotCancellable) {
		t.Fatalf("expected ErrBookingNotCancellable on second cancel, got %v", err)
	}
}

func TestCancel_CompletedBookingRejected(t *testing.T) {
	f := newFixture(t)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	if _, err := f.db.Exec(`UPDATE bookings SET status = 'completed' WHERE id = ?`, booked.Booking.ID); err != nil {
		t.Fatal(err)
	}
	_, err = booking.CancelAt(context.Background(), f.scope,
		booking.CancelRequest{BookingID: booked.Booking.ID, CancelledBy: domain.CancelledByStudent},
		func() time.Time { return f.now })
	if !errors.Is(err, booking.ErrBookingNotCancellable) {
		t.Fatalf("expected ErrBookingNotCancellable, got %v", err)
	}
}

func TestCancel_NeedsReassignmentIsStillCancellable(t *testing.T) {
	// A disrupted booking awaiting reassignment can still be cancelled
	// (e.g. cancel-with-approval is the outcome).
	f := newFixture(t)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	if _, err := f.db.Exec(`UPDATE bookings SET status = 'needs_reassignment' WHERE id = ?`, booked.Booking.ID); err != nil {
		t.Fatal(err)
	}
	res, err := booking.CancelAt(context.Background(), f.scope,
		booking.CancelRequest{BookingID: booked.Booking.ID, CancelledBy: domain.CancelledBySchool, Reason: "no swap found"},
		func() time.Time { return f.now })
	if err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if res.Booking.Status != domain.BookingCancelled {
		t.Errorf("expected cancelled, got %s", res.Booking.Status)
	}
}

func TestCancel_BookingNotFound(t *testing.T) {
	f := newFixture(t)
	_, err := booking.CancelAt(context.Background(), f.scope,
		booking.CancelRequest{BookingID: "nope", CancelledBy: domain.CancelledByStudent},
		func() time.Time { return f.now })
	if !errors.Is(err, booking.ErrBookingNotFound) {
		t.Fatalf("expected ErrBookingNotFound, got %v", err)
	}
}

func TestCancel_TenantIsolation(t *testing.T) {
	f := newFixture(t)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	other := tenant.NewScope(f.db, domain.SchoolID("school_other"))
	_, err = booking.CancelAt(context.Background(), other,
		booking.CancelRequest{BookingID: booked.Booking.ID, CancelledBy: domain.CancelledByStudent},
		func() time.Time { return f.now })
	if !errors.Is(err, booking.ErrBookingNotFound) {
		t.Fatalf("expected ErrBookingNotFound (tenant-isolated), got %v", err)
	}
}

func TestCancel_ExpectedStudentMismatchRejected(t *testing.T) {
	// Regression: in the same school, student B must not be able to cancel
	// student A's booking by passing student A's bookingId. The HTTP layer
	// fills ExpectedStudentID with the caller's UserID — a mismatch must
	// surface as ErrBookingNotFound (not a leak of "you're not the owner").
	f := newFixture(t)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	_, err = booking.CancelAt(context.Background(), f.scope,
		booking.CancelRequest{
			BookingID:         booked.Booking.ID,
			CancelledBy:       domain.CancelledByStudent,
			ExpectedStudentID: f.studentB,
		},
		func() time.Time { return f.now })
	if !errors.Is(err, booking.ErrBookingNotFound) {
		t.Fatalf("expected ErrBookingNotFound, got %v", err)
	}
}

func TestCancel_StudentCanRebookSameSession(t *testing.T) {
	// Regression: a student who cancels must be able to rebook the same
	// session if they change their mind. The partial unique index excludes
	// cancelled rows from the (school, session, student) uniqueness check.
	f := newFixture(t)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("first book: %v", err)
	}
	if _, err := booking.CancelAt(context.Background(), f.scope,
		booking.CancelRequest{BookingID: booked.Booking.ID, CancelledBy: domain.CancelledByStudent},
		func() time.Time { return f.now }); err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA}); err != nil {
		t.Fatalf("rebook after cancel should succeed, got %v", err)
	}
}

func TestCancel_FreesCapacityForAnotherStudent(t *testing.T) {
	// The whole point of cancellation: another student can take the slot.
	f := newFixture(t)
	addA1Bike(t, f, "bike_a1_second")

	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA}); err != nil {
		t.Fatalf("book A: %v", err)
	}
	booked2, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentB})
	if err != nil {
		t.Fatalf("book B: %v", err)
	}
	addStudent(t, f, "user_student_c")
	_, err = f.book(booking.Request{SessionID: f.sessionID, StudentID: "user_student_c"})
	if !errors.Is(err, booking.ErrCapacityFull) {
		t.Fatalf("expected capacity full before cancel, got %v", err)
	}

	// B cancels.
	if _, err := booking.CancelAt(context.Background(), f.scope,
		booking.CancelRequest{BookingID: booked2.Booking.ID, CancelledBy: domain.CancelledByStudent},
		func() time.Time { return f.now }); err != nil {
		t.Fatalf("cancel B: %v", err)
	}

	// Now C should fit.
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: "user_student_c"}); err != nil {
		t.Fatalf("book C after cancel: %v", err)
	}
}
