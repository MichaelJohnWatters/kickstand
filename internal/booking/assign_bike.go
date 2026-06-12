package booking

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// AssignBikeRequest swaps the bike on an existing booking. Used by the
// master-calendar edit sheet's per-row "Swap bike" picker. The
// disruption-resolve flow has its own bookkeeping (writes the
// resolution + clears `needs_reassignment` status); this path is the
// standalone equivalent for healthy bookings — manager realises the
// auto-assigned bike was wrong and picks a better one.
type AssignBikeRequest struct {
	BookingID domain.BookingID
	NewBikeID domain.BikeID
}

// AssignBike validates the candidate bike (category match, free in the
// session's window) and atomically rewrites `bookings.bike_id`. Status
// is left as-is: a `booked` booking stays booked; `needs_reassignment`
// is cleared back to `booked` so the assignment counts as a manual
// recovery from a disruption.
//
// Errors:
//   - ErrBookingNotFound when the booking doesn't exist in this tenant
//   - ErrSwapBikeNotSuitable when the candidate bike fails category,
//     transmission-preference or double-booking checks
func AssignBike(ctx context.Context, scope *tenant.Scope, req AssignBikeRequest) error {
	if req.BookingID == "" || req.NewBikeID == "" {
		return fmt.Errorf("%w: bookingId and newBikeId required", ErrSwapBikeNotSuitable)
	}
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		// Pull the session + student-transmission preference in one go.
		const q = `
			SELECT s.id, s.starts_at, s.ends_at, s.location_id,
			       ct.required_bike_category,
			       COALESCE(sp.transmission_preference, ''),
			       b.status
			FROM bookings b
			JOIN sessions s     ON s.id = b.session_id AND s.school_id = b.school_id
			JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
			LEFT JOIN student_profiles sp ON sp.user_id = b.student_id AND sp.school_id = b.school_id
			WHERE b.id = ? AND b.school_id = ?
		`
		var (
			sessID                       domain.SessionID
			startsStr, endsStr, status   string
			locationID                   domain.LocationID
			requiredCat, transmissionPref string
		)
		err := tx.Conn().QueryRowContext(ctx, q,
			string(req.BookingID), string(scope.SchoolID())).
			Scan(&sessID, &startsStr, &endsStr, &locationID, &requiredCat,
				&transmissionPref, &status)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrBookingNotFound
		}
		if err != nil {
			return fmt.Errorf("load booking for assign: %w", err)
		}
		startsAt, err := parseTime(startsStr)
		if err != nil {
			return err
		}
		endsAt, err := parseTime(endsStr)
		if err != nil {
			return err
		}
		sess := &sessionRow{
			id:                   sessID,
			startsAt:             startsAt,
			endsAt:               endsAt,
			locationID:           locationID,
			requiredBikeCategory: requiredCat,
		}
		candidates, err := findSuitableFreeBikes(ctx, tx, sess, transmissionPref)
		if err != nil {
			return err
		}
		// findSuitableFreeBikes excludes bikes already in-use on
		// overlapping sessions — but the booking we're assigning to
		// also counts as in-use of its own current bike. Re-pinning
		// to the same bike should be a no-op, not an error.
		ok := false
		for _, c := range candidates {
			if c.id == req.NewBikeID {
				ok = true
				break
			}
		}
		if !ok {
			// Allow re-assigning to the current bike (idempotent).
			var currentBike domain.BikeID
			if err := tx.Conn().QueryRowContext(ctx,
				`SELECT COALESCE(bike_id, '') FROM bookings WHERE id = ? AND school_id = ?`,
				string(req.BookingID), string(scope.SchoolID())).
				Scan(&currentBike); err != nil {
				return err
			}
			if currentBike != req.NewBikeID {
				return ErrSwapBikeNotSuitable
			}
		}
		// Apply: rewrite bike_id, lift needs_reassignment if present.
		newStatus := status
		if status == "needs_reassignment" {
			newStatus = "booked"
		}
		if _, err := tx.Conn().ExecContext(ctx, `
			UPDATE bookings SET bike_id = ?, status = ?
			WHERE id = ? AND school_id = ?
		`, string(req.NewBikeID), newStatus,
			string(req.BookingID), string(scope.SchoolID())); err != nil {
			return fmt.Errorf("apply bike assign: %w", err)
		}
		return nil
	})
}
