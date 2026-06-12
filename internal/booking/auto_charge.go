package booking

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// autoChargeForBooking writes a ledger charge for the standard course
// price when one is configured. Runs inside the booking transaction so
// the booking and the charge land atomically — there's never a window
// where the student is on a session without an owed-amount, or vice-versa.
//
// Skips silently when `price_pence` is 0/NULL — that's how schools opt
// out of standardised pricing without losing the ability to type a
// manual charge later. The charge's `booking_id` is the join key
// `voidAutoCharge` looks up on cancel.
//
// `created_by` is set to the student themselves since they're the
// actor on a self-booking. The HTTP layer should evolve to pass the
// real actor when admin-initiated bookings land.
func autoChargeForBooking(ctx context.Context, tx *tenant.Scope, b domain.Booking, courseTypeID domain.CourseTypeID, now time.Time) error {
	var price int64
	err := tx.Conn().QueryRowContext(ctx,
		`SELECT COALESCE(price_pence, 0) FROM course_types WHERE id = ? AND school_id = ?`,
		string(courseTypeID), string(tx.SchoolID()),
	).Scan(&price)
	if errors.Is(err, sql.ErrNoRows) {
		// Defensive — the booking flow already verified the course exists.
		return nil
	}
	if err != nil {
		return fmt.Errorf("lookup price: %w", err)
	}
	if price <= 0 {
		return nil
	}

	var courseName, courseCode string
	if err := tx.Conn().QueryRowContext(ctx,
		`SELECT COALESCE(name,''), COALESCE(code,'') FROM course_types WHERE id = ? AND school_id = ?`,
		string(courseTypeID), string(tx.SchoolID()),
	).Scan(&courseName, &courseCode); err != nil {
		return fmt.Errorf("lookup course label: %w", err)
	}
	desc := courseName
	if courseCode != "" {
		desc = fmt.Sprintf("%s · %s", courseCode, courseName)
	}

	at := now.UTC().Format(time.RFC3339)
	_, err = tx.Conn().ExecContext(ctx, `
		INSERT INTO charges
		    (id, school_id, student_id, booking_id, amount_pence,
		     description, incurred_at, created_at, created_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, domain.NewID(), string(tx.SchoolID()), string(b.StudentID), string(b.ID),
		price, desc, at, at, string(b.StudentID))
	if err != nil {
		return fmt.Errorf("insert auto-charge: %w", err)
	}
	return nil
}

// voidAutoCharge nulls out any active charges linked to a booking.
// Idempotent — no auto-charge means no rows updated, which is fine.
// `voidedBy` may be empty for school-initiated cancels where the actor
// isn't threaded through the request.
func voidAutoCharge(ctx context.Context, tx *tenant.Scope, bookingID domain.BookingID, voidedBy domain.UserID, now time.Time) error {
	at := now.UTC().Format(time.RFC3339)
	var actorArg any
	if voidedBy != "" {
		actorArg = string(voidedBy)
	}
	_, err := tx.Conn().ExecContext(ctx, `
		UPDATE charges
		   SET voided_at = ?, voided_by = ?, void_reason = 'booking_cancelled'
		 WHERE school_id = ? AND booking_id = ? AND voided_at IS NULL
	`, at, actorArg, string(tx.SchoolID()), string(bookingID))
	if err != nil {
		return fmt.Errorf("void auto-charge: %w", err)
	}
	return nil
}
