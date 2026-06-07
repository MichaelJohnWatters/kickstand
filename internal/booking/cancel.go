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

// CancelRequest describes a cancellation attempt.
type CancelRequest struct {
	BookingID   domain.BookingID
	CancelledBy domain.CancelledBy // 'student' or 'school'
	Reason      string             // optional free text

	// ExpectedStudentID, if non-empty, asserts the booking belongs to this
	// student — used by the HTTP layer to prevent a student from cancelling
	// another student's booking in the same school. A mismatch returns
	// ErrBookingNotFound so callers can't probe for foreign booking IDs.
	ExpectedStudentID domain.UserID
}

// CancelResult carries the post-cancel booking plus whether the cancel was
// "late" relative to the school's cancel_cutoff_hours. Late is informational
// only — the cancel itself always succeeds if the booking is in a cancellable
// state. Plan §8 keeps late-cancellation charging out of MVP; the UI shows
// the policy.
type CancelResult struct {
	Booking domain.Booking
	Late    bool
}

var (
	ErrBookingNotFound       = errors.New("booking: not found in this school")
	ErrBookingNotCancellable = errors.New("booking: cannot cancel (already cancelled or completed)")
)

// Cancel runs the cancellation in an IMMEDIATE transaction. Sets status,
// cancelled_by, reason, and cancelled_at on the booking row.
func Cancel(ctx context.Context, scope *tenant.Scope, req CancelRequest) (*CancelResult, error) {
	return CancelAt(ctx, scope, req, time.Now)
}

// CancelAt is the testable form — exposes the clock.
func CancelAt(ctx context.Context, scope *tenant.Scope, req CancelRequest, nowFn func() time.Time) (*CancelResult, error) {
	var out *CancelResult
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		r, err := cancelInTx(ctx, tx, req, nowFn())
		if err != nil {
			return err
		}
		name, _ := sessionCourseName(ctx, tx, r.Booking.SessionID)
		instructor, _ := sessionInstructor(ctx, tx, r.Booking.SessionID)
		if err := notify.OnBookingCancelled(ctx, tx, r.Booking, req.CancelledBy, name, instructor); err != nil {
			return err
		}
		out = r
		return nil
	})
	return out, err
}

func cancelInTx(ctx context.Context, tx *tenant.Scope, req CancelRequest, now time.Time) (*CancelResult, error) {
	if req.CancelledBy != domain.CancelledByStudent && req.CancelledBy != domain.CancelledBySchool {
		return nil, fmt.Errorf("booking: invalid cancelled_by %q", req.CancelledBy)
	}

	// Lock and load: read the booking row + the school's cutoff + the
	// session start time in a single query so we don't round-trip and so
	// the values are stable inside the tx.
	const loadQ = `
		SELECT b.id, b.school_id, b.session_id, b.student_id,
		       COALESCE(b.bike_id, ''), b.status,
		       COALESCE(b.cancelled_by, ''), COALESCE(b.cancellation_reason, ''),
		       COALESCE(b.notes, ''), b.created_at, COALESCE(b.cancelled_at, ''),
		       s.starts_at, sch.cancel_cutoff_hours
		FROM bookings b
		JOIN sessions s ON s.id = b.session_id AND s.school_id = b.school_id
		JOIN schools  sch ON sch.id = b.school_id
		WHERE b.id = ? AND b.school_id = ?
	`
	row := tx.Conn().QueryRowContext(ctx, loadQ, string(req.BookingID), string(tx.SchoolID()))

	var (
		b                domain.Booking
		startsStr        string
		createdStr       string
		cancelledStr     string
		cancelCutoffHrs  int
	)
	err := row.Scan(
		&b.ID, &b.SchoolID, &b.SessionID, &b.StudentID,
		&b.BikeID, &b.Status,
		&b.CancelledBy, &b.CancellationReason,
		&b.Notes, &createdStr, &cancelledStr,
		&startsStr, &cancelCutoffHrs,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrBookingNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load booking: %w", err)
	}

	if req.ExpectedStudentID != "" && b.StudentID != req.ExpectedStudentID {
		return nil, ErrBookingNotFound
	}

	if b.Status != domain.BookingBooked && b.Status != domain.BookingNeedsReassignment {
		return nil, ErrBookingNotCancellable
	}

	if b.CreatedAt, err = parseTime(createdStr); err != nil {
		return nil, fmt.Errorf("parse created_at: %w", err)
	}
	sessionStart, err := parseTime(startsStr)
	if err != nil {
		return nil, fmt.Errorf("parse session start: %w", err)
	}
	late := now.Add(time.Duration(cancelCutoffHrs)*time.Hour).After(sessionStart)

	cancelledAt := now.UTC().Format(time.RFC3339)
	const updQ = `
		UPDATE bookings
		   SET status = 'cancelled',
		       cancelled_by = ?,
		       cancellation_reason = ?,
		       cancelled_at = ?
		 WHERE id = ? AND school_id = ?
		   AND status IN ('booked', 'needs_reassignment')
	`
	res, err := tx.Conn().ExecContext(ctx, updQ,
		string(req.CancelledBy), req.Reason, cancelledAt,
		string(req.BookingID), string(tx.SchoolID()),
	)
	if err != nil {
		return nil, fmt.Errorf("update booking: %w", err)
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return nil, err
	}
	if rows == 0 {
		// Lost a race against another cancel / state change.
		return nil, ErrBookingNotCancellable
	}

	b.Status = domain.BookingCancelled
	b.CancelledBy = req.CancelledBy
	b.CancellationReason = req.Reason
	b.CancelledAt = now.UTC()
	return &CancelResult{Booking: b, Late: late}, nil
}
