package booking

import (
	"context"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/notify"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// CancelSessionResult counts what the cancellation did for the UI's
// confirmation toast.
type CancelSessionResult struct {
	SessionID         domain.SessionID
	BookingsCancelled int
	WaitlistDropped   int
}

// CancelSession cancels every active booking on a session, voids
// their auto-charges, notifies the affected students, and marks the
// session itself cancelled. All in one transaction.
//
// Used for the manager's "rainy day" workflow — bulk cancel via the
// calendar — but the engine call is independent and reusable from
// any caller that needs to scrub a session.
//
// Idempotent on the session-level state change: an already-cancelled
// session returns nil with zero counts (no error). Booking-level
// cancels skip rows that aren't in a cancellable state.
func CancelSession(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID, reason string) (*CancelSessionResult, error) {
	return CancelSessionAt(ctx, scope, sessionID, reason, time.Now)
}

// CancelSessionAt is the testable form — exposes the clock so tests
// can pin "now" to a deterministic moment.
func CancelSessionAt(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID, reason string, nowFn func() time.Time) (*CancelSessionResult, error) {
	out := &CancelSessionResult{SessionID: sessionID}
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		// Lock + read the session so we don't race against a parallel
		// booking attempting to land on this same session.
		sess, err := loadSession(ctx, tx, sessionID)
		if err != nil {
			return err
		}
		if sess.status == "cancelled" {
			return nil // idempotent
		}

		// Drop the waitlist BEFORE cancelling bookings, otherwise each
		// per-booking cancel auto-promotes the next waitlister into the
		// session we're killing — wasteful and confusing for the
		// student. With an empty queue, the promotion path is a no-op.
		dropRes, err := tx.Conn().ExecContext(ctx, `
			DELETE FROM waitlist_entries
			WHERE school_id = ? AND session_id = ? AND promoted_at IS NULL
		`, string(tx.SchoolID()), string(sessionID))
		if err != nil {
			return fmt.Errorf("drop waitlist: %w", err)
		}
		dropped, _ := dropRes.RowsAffected()
		out.WaitlistDropped = int(dropped)

		// Cancel every active booking. We loop one at a time through
		// cancelInTx so each pass also voids the auto-charge and runs
		// the per-booking notify hook. notification ordering doesn't
		// matter — they all fire inside the same tx.
		rows, err := tx.Conn().QueryContext(ctx, `
			SELECT id FROM bookings
			WHERE school_id = ? AND session_id = ?
			  AND status IN ('booked', 'needs_reassignment')
		`, string(tx.SchoolID()), string(sessionID))
		if err != nil {
			return fmt.Errorf("read bookings: %w", err)
		}
		var bookingIDs []domain.BookingID
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			bookingIDs = append(bookingIDs, domain.BookingID(id))
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}

		courseName, _ := sessionCourseName(ctx, tx, sessionID)
		for _, bID := range bookingIDs {
			res, err := cancelInTx(ctx, tx, CancelRequest{
				BookingID:   bID,
				CancelledBy: domain.CancelledBySchool,
				Reason:      reason,
			}, nowFn())
			if err != nil {
				// Defensive: a single failed booking shouldn't block the
				// rest. We surface as an error since the tx will roll
				// back anyway — partial cancels would be confusing.
				return fmt.Errorf("cancel booking %s: %w", bID, err)
			}
			if err := notify.OnBookingCancelled(ctx, tx, res.Booking,
				domain.CancelledBySchool, courseName, sess.instructorID); err != nil {
				return err
			}
			out.BookingsCancelled++
		}

		// Mark the session itself cancelled.
		if _, err := tx.Conn().ExecContext(ctx, `
			UPDATE sessions SET status = 'cancelled'
			WHERE id = ? AND school_id = ?
		`, string(sessionID), string(tx.SchoolID())); err != nil {
			return fmt.Errorf("cancel session: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

