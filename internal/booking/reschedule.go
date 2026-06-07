package booking

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/notify"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// RescheduleRequest moves a student from one session to another.
//
// Per plan §8 (deferred): MVP reschedule = cancel + rebook. A "true" atomic
// reschedule that re-runs the full availability check is the same thing
// implemented carefully — and that's what we do here: both operations run
// inside ONE transaction, so a failed rebook rolls the cancel back and the
// student keeps their original slot. Without that, a student trying to move
// could lose their booking to "session full" with no recourse.
type RescheduleRequest struct {
	BookingID    domain.BookingID
	NewSessionID domain.SessionID
	NewBikeID    domain.BikeID      // "" = auto-assign
	CancelledBy  domain.CancelledBy // attribution for the cancel half
	Reason       string

	// ExpectedStudentID, if non-empty, asserts the original booking belongs
	// to this student. Same guarantee as CancelRequest.ExpectedStudentID:
	// prevents a student from rescheduling someone else's booking.
	ExpectedStudentID domain.UserID
}

// RescheduleResult exposes both halves so callers can audit / display the
// transition. Advisories come from the new booking; CancelWasLate is the
// cutoff-flag from the cancel half (UI policy display).
type RescheduleResult struct {
	CancelledBooking domain.Booking
	NewBooking       domain.Booking
	Advisories       []Advisory
	CancelWasLate    bool
}

func Reschedule(ctx context.Context, scope *tenant.Scope, req RescheduleRequest) (*RescheduleResult, error) {
	return RescheduleAt(ctx, scope, req, time.Now)
}

func RescheduleAt(ctx context.Context, scope *tenant.Scope, req RescheduleRequest, nowFn func() time.Time) (*RescheduleResult, error) {
	var out *RescheduleResult
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		r, err := rescheduleInTx(ctx, tx, req, nowFn())
		if err != nil {
			return err
		}
		// One single rescheduled event for the pair — keeps the bell from
		// showing both a "cancelled" and a "booked" entry for what's really
		// a move.
		name, _ := sessionCourseName(ctx, tx, r.NewBooking.SessionID)
		if err := notify.OnBookingRescheduled(ctx, tx, r.CancelledBooking, r.NewBooking, name); err != nil {
			return err
		}
		out = r
		return nil
	})
	return out, err
}

func rescheduleInTx(ctx context.Context, tx *tenant.Scope, req RescheduleRequest, now time.Time) (*RescheduleResult, error) {
	// Look up the student on the original booking — reschedule keeps the
	// same student; the caller doesn't need to pass it.
	var studentID domain.UserID
	err := tx.Conn().QueryRowContext(ctx,
		`SELECT student_id FROM bookings WHERE id = ? AND school_id = ?`,
		string(req.BookingID), string(tx.SchoolID()),
	).Scan(&studentID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrBookingNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load original booking: %w", err)
	}

	if req.ExpectedStudentID != "" && studentID != req.ExpectedStudentID {
		return nil, ErrBookingNotFound
	}

	cancelRes, err := cancelInTx(ctx, tx, CancelRequest{
		BookingID:         req.BookingID,
		CancelledBy:       req.CancelledBy,
		Reason:            req.Reason,
		ExpectedStudentID: req.ExpectedStudentID,
	}, now)
	if err != nil {
		return nil, err
	}

	// Now that the old booking is cancelled (within this tx, so its bike
	// and slot are freed for our visibility), try to book the new one.
	// If this fails, the tx rolls back and the student keeps their old slot.
	bookRes, err := bookInTx(ctx, tx, Request{
		SessionID: req.NewSessionID,
		StudentID: studentID,
		BikeID:    req.NewBikeID,
	}, now)
	if err != nil {
		return nil, err
	}

	return &RescheduleResult{
		CancelledBooking: cancelRes.Booking,
		NewBooking:       bookRes.Booking,
		Advisories:       bookRes.Advisories,
		CancelWasLate:    cancelRes.Late,
	}, nil
}
