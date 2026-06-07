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

// This file implements plan §6 — disruption handling. Two distinct things:
//
//  1. Take the bike offline (creates a bike_unavailability row from "now"
//     forward). Stops it appearing in future availability immediately.
//
//  2. Resolve already-assigned bookings from the breakage forward, with
//     three possible outcomes per booking:
//        - swap (reassign a suitable free bike — the happy path),
//        - cancel-with-approval (no swap exists; blameless, slot held),
//        - pending (sits in needs_reassignment until a human acts).
//
// Per plan §9 leaning #3 (confirmed): a disrupted booking awaiting approval
// HOLDS the slot for the student — the booking row stays, just with
// status='needs_reassignment'. Capacity stays consumed.

// TakeBikeOfflineRequest describes a bike-down event.
type TakeBikeOfflineRequest struct {
	BikeID    domain.BikeID
	Reason    string // 'mechanic' | 'damaged' | 'broken' | 'off_road' | 'other'
	StartsAt  time.Time
	EndsAt    time.Time // use far-future for indefinite
	Notes     string
	CreatedBy domain.UserID
}

// TakeBikeOfflineResult bundles everything the UI needs to drive the
// per-affected-booking resolution sheet: the disruption record, plus
// for each affected booking the swap candidates (deterministically ordered,
// best first) so the manager can accept the suggestion or pick another.
type TakeBikeOfflineResult struct {
	DisruptionID     domain.DisruptionID
	AffectedBookings []AffectedBooking
}

type AffectedBooking struct {
	BookingID       domain.BookingID
	SessionID       domain.SessionID
	StudentID       domain.UserID
	SessionStartsAt time.Time
	SessionEndsAt   time.Time
	SwapCandidates  []SwapCandidate
}

type SwapCandidate struct {
	BikeID            domain.BikeID
	BikeNickname      string
	BikeRegistration  string
	CurrentLocationID domain.LocationID
	IsCrossSite       bool
}

var (
	ErrBikeNotFound         = errors.New("disruption: bike not found in this school")
	ErrInvalidWindow        = errors.New("disruption: ends_at must be after starts_at")
	ErrDisruptionNotFound   = errors.New("disruption: not found in this school")
	ErrNotAffectedByThis    = errors.New("disruption: booking is not affected by this disruption")
	ErrSwapBikeNotSuitable  = errors.New("disruption: proposed swap bike is not a valid candidate")
	ErrAlreadyResolved      = errors.New("disruption: booking resolution already recorded")
)

// TakeBikeOffline runs the entire detection+linking step in one transaction:
// inserts the bike_unavailability, opens a disruption record, finds all
// affected bookings, flips each to needs_reassignment, and computes swap
// candidates for the UI.
func TakeBikeOffline(ctx context.Context, scope *tenant.Scope, req TakeBikeOfflineRequest) (*TakeBikeOfflineResult, error) {
	return takeBikeOfflineAt(ctx, scope, req, time.Now)
}

func takeBikeOfflineAt(ctx context.Context, scope *tenant.Scope, req TakeBikeOfflineRequest, nowFn func() time.Time) (*TakeBikeOfflineResult, error) {
	if !req.EndsAt.After(req.StartsAt) {
		return nil, ErrInvalidWindow
	}

	var out *TakeBikeOfflineResult
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		r, err := takeBikeOfflineInTx(ctx, tx, req, nowFn())
		if err != nil {
			return err
		}
		out = r
		return nil
	})
	return out, err
}

func takeBikeOfflineInTx(ctx context.Context, tx *tenant.Scope, req TakeBikeOfflineRequest, now time.Time) (*TakeBikeOfflineResult, error) {
	// Confirm the bike belongs to the scope's tenant. The query result also
	// tells us it exists.
	var exists int
	err := tx.Conn().QueryRowContext(ctx,
		`SELECT 1 FROM bikes WHERE id = ? AND school_id = ?`,
		string(req.BikeID), string(tx.SchoolID()),
	).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrBikeNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("check bike: %w", err)
	}

	// 1. Insert bike_unavailability so future availability queries skip this bike.
	unavailID := domain.NewID()
	_, err = tx.Conn().ExecContext(ctx, `
		INSERT INTO bike_unavailability (id, school_id, bike_id, reason,
		    starts_at, ends_at, notes, created_at, created_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		unavailID, string(tx.SchoolID()), string(req.BikeID), req.Reason,
		req.StartsAt.UTC().Format(time.RFC3339),
		req.EndsAt.UTC().Format(time.RFC3339),
		req.Notes,
		now.UTC().Format(time.RFC3339),
		string(req.CreatedBy),
	)
	if err != nil {
		return nil, fmt.Errorf("insert bike_unavailability: %w", err)
	}

	// 2. Also flip the bike's own status to 'offline' so the bike list shows
	//    it correctly. The unavailability row is the authoritative window;
	//    the status is the at-a-glance signal.
	if _, err := tx.Conn().ExecContext(ctx,
		`UPDATE bikes SET status = 'offline' WHERE id = ? AND school_id = ?`,
		string(req.BikeID), string(tx.SchoolID()),
	); err != nil {
		return nil, fmt.Errorf("mark bike offline: %w", err)
	}

	// 3. Create the disruption record.
	disruptionID := domain.NewID()
	_, err = tx.Conn().ExecContext(ctx, `
		INSERT INTO disruptions (id, school_id, bike_id, started_at, reason, created_by)
		VALUES (?, ?, ?, ?, ?, ?)
	`,
		disruptionID, string(tx.SchoolID()), string(req.BikeID),
		now.UTC().Format(time.RFC3339), req.Reason, string(req.CreatedBy),
	)
	if err != nil {
		return nil, fmt.Errorf("insert disruption: %w", err)
	}

	// 4. Find affected bookings: active bookings on this bike whose session
	//    overlaps the unavailability window.
	const affectedQ = `
		SELECT b.id, b.session_id, b.student_id, s.starts_at, s.ends_at,
		       s.location_id, ct.required_bike_category,
		       COALESCE(sp.transmission_preference, '')
		FROM bookings b
		JOIN sessions s     ON s.id = b.session_id AND s.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN student_profiles sp ON sp.user_id = b.student_id AND sp.school_id = b.school_id
		WHERE b.school_id = ?
		  AND b.bike_id = ?
		  AND b.status IN ('booked', 'needs_reassignment')
		  AND s.starts_at < ?
		  AND s.ends_at   > ?
		ORDER BY s.starts_at ASC
	`
	rows, err := tx.Conn().QueryContext(ctx, affectedQ,
		string(tx.SchoolID()), string(req.BikeID),
		req.EndsAt.UTC().Format(time.RFC3339),
		req.StartsAt.UTC().Format(time.RFC3339),
	)
	if err != nil {
		return nil, fmt.Errorf("find affected bookings: %w", err)
	}

	type affectedRow struct {
		ab               AffectedBooking
		locationID       domain.LocationID
		requiredCategory string
		transmissionPref string
	}
	var affected []affectedRow
	for rows.Next() {
		var (
			r          affectedRow
			startsStr  string
			endsStr    string
		)
		if err := rows.Scan(
			&r.ab.BookingID, &r.ab.SessionID, &r.ab.StudentID,
			&startsStr, &endsStr,
			&r.locationID, &r.requiredCategory, &r.transmissionPref,
		); err != nil {
			rows.Close()
			return nil, err
		}
		r.ab.SessionStartsAt, err = parseTime(startsStr)
		if err != nil {
			rows.Close()
			return nil, fmt.Errorf("parse session start: %w", err)
		}
		r.ab.SessionEndsAt, err = parseTime(endsStr)
		if err != nil {
			rows.Close()
			return nil, fmt.Errorf("parse session end: %w", err)
		}
		affected = append(affected, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// 5. For each affected booking: insert a disruption_affected_bookings row
	//    (resolution='pending'), flip the booking to needs_reassignment, and
	//    compute swap candidates using the same predicate the booking engine
	//    uses to find suitable bikes.
	for i, r := range affected {
		if _, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO disruption_affected_bookings
			    (school_id, disruption_id, booking_id, resolution)
			VALUES (?, ?, ?, 'pending')
		`, string(tx.SchoolID()), disruptionID, string(r.ab.BookingID)); err != nil {
			return nil, fmt.Errorf("insert affected booking: %w", err)
		}

		if _, err := tx.Conn().ExecContext(ctx, `
			UPDATE bookings SET status = 'needs_reassignment'
			WHERE id = ? AND school_id = ? AND status = 'booked'
		`, string(r.ab.BookingID), string(tx.SchoolID())); err != nil {
			return nil, fmt.Errorf("flip booking to needs_reassignment: %w", err)
		}

		// Build a sessionRow-shaped value to feed findSuitableFreeBikes.
		// findSuitableFreeBikes filters out bikes that are in an
		// unavailability overlapping the session window — we just inserted
		// one for this bike, so it won't appear in the candidates. Good.
		sess := &sessionRow{
			id:                   r.ab.SessionID,
			startsAt:             r.ab.SessionStartsAt,
			endsAt:               r.ab.SessionEndsAt,
			locationID:           r.locationID,
			requiredBikeCategory: r.requiredCategory,
		}
		bikes, err := findSuitableFreeBikes(ctx, tx, sess, r.transmissionPref)
		if err != nil {
			return nil, fmt.Errorf("find swap candidates: %w", err)
		}
		for _, b := range bikes {
			affected[i].ab.SwapCandidates = append(affected[i].ab.SwapCandidates, SwapCandidate{
				BikeID:            b.id,
				CurrentLocationID: b.currentLocationID,
				IsCrossSite:       b.currentLocationID != r.locationID,
			})
		}
	}

	out := &TakeBikeOfflineResult{
		DisruptionID:     domain.DisruptionID(disruptionID),
		AffectedBookings: make([]AffectedBooking, 0, len(affected)),
	}
	for _, r := range affected {
		out.AffectedBookings = append(out.AffectedBookings, r.ab)
	}

	// Notifications: ping admins (bike down, your attention needed) and
	// each affected student (your session is being reassigned). All within
	// the same tx so no notification can exist without its disruption row.
	if err := notify.OnBikeOffline(ctx, tx, req.BikeID, out.DisruptionID, len(out.AffectedBookings)); err != nil {
		return nil, err
	}
	for _, ab := range out.AffectedBookings {
		// Build a minimal Booking value for the hook.
		b := domain.Booking{
			ID: ab.BookingID, SchoolID: tx.SchoolID(),
			SessionID: ab.SessionID, StudentID: ab.StudentID,
		}
		if err := notify.OnDisruptionAffected(ctx, tx, b, out.DisruptionID); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// ResolveAffectedBooking applies a resolution to one disrupted booking.
// Three resolutions are supported, matching plan §6:
//
//   - ResolveSwap: a specific bike is assigned. The bike must be in the
//     current swap-candidate set (re-checked inside the tx so a bike
//     someone else just took isn't double-assigned).
//   - ResolveCancelWithApproval: no swap; booking is cancelled with
//     'school' attribution. Slot is freed (capacity restored).
//   - ResolvePending: leaves the booking in needs_reassignment but updates
//     a note. (Mostly for completeness; usually you'd just not act.)
type ResolutionKind string

const (
	ResolveSwap               ResolutionKind = "swapped"
	ResolveCancelWithApproval ResolutionKind = "cancel_with_approval"
)

type ResolveAffectedBookingRequest struct {
	DisruptionID domain.DisruptionID
	BookingID    domain.BookingID
	Resolution   ResolutionKind
	NewBikeID    domain.BikeID // required when Resolution == ResolveSwap
	ApprovedBy   domain.UserID // who's making the call (for cancel attribution)
	Notes        string
}

func ResolveAffectedBooking(ctx context.Context, scope *tenant.Scope, req ResolveAffectedBookingRequest) error {
	return resolveAffectedBookingAt(ctx, scope, req, time.Now)
}

func resolveAffectedBookingAt(ctx context.Context, scope *tenant.Scope, req ResolveAffectedBookingRequest, nowFn func() time.Time) error {
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		return resolveInTx(ctx, tx, req, nowFn())
	})
}

func resolveInTx(ctx context.Context, tx *tenant.Scope, req ResolveAffectedBookingRequest, now time.Time) error {
	// Verify the link exists and is still 'pending'. If someone else already
	// resolved it, fail loudly rather than silently overwriting.
	var currentResolution string
	err := tx.Conn().QueryRowContext(ctx, `
		SELECT resolution FROM disruption_affected_bookings
		WHERE disruption_id = ? AND booking_id = ?
		  AND school_id = ?
	`, string(req.DisruptionID), string(req.BookingID), string(tx.SchoolID())).Scan(&currentResolution)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotAffectedByThis
	}
	if err != nil {
		return fmt.Errorf("load affected link: %w", err)
	}
	if currentResolution != "pending" {
		return ErrAlreadyResolved
	}

	switch req.Resolution {
	case ResolveSwap:
		return applySwapInTx(ctx, tx, req, now)
	case ResolveCancelWithApproval:
		return applyCancelWithApprovalInTx(ctx, tx, req, now)
	default:
		return fmt.Errorf("disruption: unknown resolution %q", req.Resolution)
	}
}

// loadAffectedBookingForNotify returns the minimal Booking shape needed by
// the notify hooks — we need student_id at minimum. Avoids a wider join
// than the resolve paths needed before.
func loadAffectedBookingForNotify(ctx context.Context, tx *tenant.Scope, bookingID domain.BookingID) (domain.Booking, error) {
	var b domain.Booking
	err := tx.Conn().QueryRowContext(ctx, `
		SELECT id, school_id, session_id, student_id, COALESCE(bike_id, ''), status
		FROM bookings WHERE id = ? AND school_id = ?
	`, string(bookingID), string(tx.SchoolID())).Scan(
		&b.ID, &b.SchoolID, &b.SessionID, &b.StudentID, &b.BikeID, &b.Status,
	)
	return b, err
}

func applySwapInTx(ctx context.Context, tx *tenant.Scope, req ResolveAffectedBookingRequest, now time.Time) error {
	if req.NewBikeID == "" {
		return ErrSwapBikeNotSuitable
	}

	// Re-fetch the session details for the candidate check.
	const sessQ = `
		SELECT s.id, s.starts_at, s.ends_at, s.location_id,
		       ct.required_bike_category,
		       COALESCE(sp.transmission_preference, '')
		FROM bookings b
		JOIN sessions s     ON s.id = b.session_id AND s.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN student_profiles sp ON sp.user_id = b.student_id AND sp.school_id = b.school_id
		WHERE b.id = ? AND b.school_id = ?
	`
	var (
		sessID                   domain.SessionID
		startsStr, endsStr       string
		locationID               domain.LocationID
		requiredCat, transmission string
	)
	if err := tx.Conn().QueryRowContext(ctx, sessQ, string(req.BookingID), string(tx.SchoolID())).
		Scan(&sessID, &startsStr, &endsStr, &locationID, &requiredCat, &transmission); err != nil {
		return fmt.Errorf("load session for swap: %w", err)
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
	candidates, err := findSuitableFreeBikes(ctx, tx, sess, transmission)
	if err != nil {
		return err
	}
	suitable := false
	for _, c := range candidates {
		if c.id == req.NewBikeID {
			suitable = true
			break
		}
	}
	if !suitable {
		return ErrSwapBikeNotSuitable
	}

	// Apply the swap: assign new bike, flip status back to 'booked'.
	if _, err := tx.Conn().ExecContext(ctx, `
		UPDATE bookings SET bike_id = ?, status = 'booked'
		WHERE id = ? AND school_id = ? AND status = 'needs_reassignment'
	`, string(req.NewBikeID), string(req.BookingID), string(tx.SchoolID())); err != nil {
		return fmt.Errorf("apply swap to booking: %w", err)
	}

	// Mark the disruption link.
	if _, err := tx.Conn().ExecContext(ctx, `
		UPDATE disruption_affected_bookings
		   SET resolution = 'swapped',
		       new_bike_id = ?,
		       resolved_at = ?
		 WHERE disruption_id = ? AND booking_id = ? AND school_id = ?
	`, string(req.NewBikeID), now.UTC().Format(time.RFC3339),
		string(req.DisruptionID), string(req.BookingID), string(tx.SchoolID())); err != nil {
		return fmt.Errorf("update disruption link: %w", err)
	}

	// Notify the student that the swap is done.
	b, err := loadAffectedBookingForNotify(ctx, tx, req.BookingID)
	if err == nil {
		_ = notify.OnDisruptionResolved(ctx, tx, b, req.DisruptionID, "swapped")
	}
	return nil
}

func applyCancelWithApprovalInTx(ctx context.Context, tx *tenant.Scope, req ResolveAffectedBookingRequest, now time.Time) error {
	reason := req.Notes
	if reason == "" {
		reason = "Bike unavailable; no suitable swap found."
	}
	if _, err := tx.Conn().ExecContext(ctx, `
		UPDATE bookings
		   SET status = 'cancelled',
		       cancelled_by = 'school',
		       cancellation_reason = ?,
		       cancelled_at = ?
		 WHERE id = ? AND school_id = ? AND status = 'needs_reassignment'
	`, reason, now.UTC().Format(time.RFC3339),
		string(req.BookingID), string(tx.SchoolID())); err != nil {
		return fmt.Errorf("cancel-with-approval booking: %w", err)
	}
	if _, err := tx.Conn().ExecContext(ctx, `
		UPDATE disruption_affected_bookings
		   SET resolution = 'cancel_with_approval',
		       resolved_at = ?
		 WHERE disruption_id = ? AND booking_id = ? AND school_id = ?
	`, now.UTC().Format(time.RFC3339),
		string(req.DisruptionID), string(req.BookingID), string(tx.SchoolID())); err != nil {
		return fmt.Errorf("update disruption link (cancel): %w", err)
	}

	// Notify the student that their booking was cancelled via the
	// disruption flow (distinct from a normal cancel — uses the
	// disruption.resolved event so the UI can render the right copy).
	b, err := loadAffectedBookingForNotify(ctx, tx, req.BookingID)
	if err == nil {
		_ = notify.OnDisruptionResolved(ctx, tx, b, req.DisruptionID, "cancel_with_approval")
	}
	return nil
}
