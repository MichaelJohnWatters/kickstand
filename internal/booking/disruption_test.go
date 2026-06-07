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

func takeOffline(t *testing.T, f *testFixture, bikeID domain.BikeID, hoursOut int) *booking.TakeBikeOfflineResult {
	t.Helper()
	startsAt := f.now.Add(time.Duration(hoursOut) * time.Hour)
	endsAt := f.now.AddDate(1, 0, 0) // ~indefinite
	res, err := booking.TakeBikeOffline(context.Background(), f.scope,
		booking.TakeBikeOfflineRequest{
			BikeID:    bikeID,
			Reason:    "damaged",
			StartsAt:  startsAt,
			EndsAt:    endsAt,
			Notes:     "front-brake failure",
			CreatedBy: f.instructor,
		},
	)
	if err != nil {
		t.Fatalf("take bike offline: %v", err)
	}
	return res
}

func TestDisruption_NoAffectedBookings(t *testing.T) {
	f := newFixture(t)
	res := takeOffline(t, f, f.bikeA2, 1) // A2 isn't assigned to anyone yet
	if len(res.AffectedBookings) != 0 {
		t.Errorf("expected 0 affected, got %d", len(res.AffectedBookings))
	}

	// Bike should now be marked offline.
	var status string
	if err := f.db.QueryRow(`SELECT status FROM bikes WHERE id = ?`, f.bikeA2).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if status != "offline" {
		t.Errorf("expected bike status 'offline', got %q", status)
	}
}

func TestDisruption_FindsAffectedBookingAndSuggestsSwap(t *testing.T) {
	f := newFixture(t)
	addA1Bike(t, f, "bike_a1_spare") // gives us a swap candidate

	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("initial book: %v", err)
	}
	// Take the booked bike (bikeA1) offline starting now.
	res := takeOffline(t, f, booked.Booking.BikeID, 0)

	if len(res.AffectedBookings) != 1 {
		t.Fatalf("expected 1 affected booking, got %d", len(res.AffectedBookings))
	}
	ab := res.AffectedBookings[0]
	if ab.BookingID != booked.Booking.ID {
		t.Errorf("expected booking %s in affected list, got %s", booked.Booking.ID, ab.BookingID)
	}
	if len(ab.SwapCandidates) == 0 {
		t.Errorf("expected a swap candidate (spare A1)")
	}
	if len(ab.SwapCandidates) > 0 && ab.SwapCandidates[0].BikeID != "bike_a1_spare" {
		t.Errorf("expected spare A1 as candidate, got %s", ab.SwapCandidates[0].BikeID)
	}

	// The booking's status should now be needs_reassignment.
	var status string
	if err := f.db.QueryRow(`SELECT status FROM bookings WHERE id = ?`, booked.Booking.ID).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if status != "needs_reassignment" {
		t.Errorf("expected status needs_reassignment, got %q", status)
	}
}

func TestDisruption_ResolveSwap_AssignsBikeAndRestoresStatus(t *testing.T) {
	f := newFixture(t)
	addA1Bike(t, f, "bike_a1_spare")

	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	disrupt := takeOffline(t, f, booked.Booking.BikeID, 0)

	err = booking.ResolveAffectedBooking(context.Background(), f.scope,
		booking.ResolveAffectedBookingRequest{
			DisruptionID: disrupt.DisruptionID,
			BookingID:    booked.Booking.ID,
			Resolution:   booking.ResolveSwap,
			NewBikeID:    "bike_a1_spare",
			ApprovedBy:   f.instructor,
		},
	)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}

	var status, bikeID string
	if err := f.db.QueryRow(`SELECT status, bike_id FROM bookings WHERE id = ?`, booked.Booking.ID).
		Scan(&status, &bikeID); err != nil {
		t.Fatal(err)
	}
	if status != "booked" {
		t.Errorf("expected status booked after swap, got %q", status)
	}
	if bikeID != "bike_a1_spare" {
		t.Errorf("expected bike swapped to spare, got %q", bikeID)
	}

	// Disruption link should be marked swapped.
	var resolution, newBike string
	if err := f.db.QueryRow(`SELECT resolution, COALESCE(new_bike_id,'') FROM disruption_affected_bookings
	                         WHERE disruption_id = ? AND booking_id = ?`,
		disrupt.DisruptionID, booked.Booking.ID).Scan(&resolution, &newBike); err != nil {
		t.Fatal(err)
	}
	if resolution != "swapped" || newBike != "bike_a1_spare" {
		t.Errorf("disruption link: got resolution=%q new_bike=%q", resolution, newBike)
	}
}

func TestDisruption_ResolveSwap_RejectsUnsuitableBike(t *testing.T) {
	f := newFixture(t)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	disrupt := takeOffline(t, f, booked.Booking.BikeID, 0)

	// Try to swap to the A2 bike — wrong category for CBT 125.
	err = booking.ResolveAffectedBooking(context.Background(), f.scope,
		booking.ResolveAffectedBookingRequest{
			DisruptionID: disrupt.DisruptionID,
			BookingID:    booked.Booking.ID,
			Resolution:   booking.ResolveSwap,
			NewBikeID:    f.bikeA2,
			ApprovedBy:   f.instructor,
		},
	)
	if !errors.Is(err, booking.ErrSwapBikeNotSuitable) {
		t.Fatalf("expected ErrSwapBikeNotSuitable, got %v", err)
	}
}

func TestDisruption_ResolveCancelWithApproval(t *testing.T) {
	f := newFixture(t)
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	disrupt := takeOffline(t, f, booked.Booking.BikeID, 0)

	err = booking.ResolveAffectedBooking(context.Background(), f.scope,
		booking.ResolveAffectedBookingRequest{
			DisruptionID: disrupt.DisruptionID,
			BookingID:    booked.Booking.ID,
			Resolution:   booking.ResolveCancelWithApproval,
			ApprovedBy:   f.instructor,
		},
	)
	if err != nil {
		t.Fatalf("cancel-with-approval: %v", err)
	}

	var status, cancelledBy, reason string
	if err := f.db.QueryRow(`SELECT status, COALESCE(cancelled_by,''), COALESCE(cancellation_reason,'')
	                         FROM bookings WHERE id = ?`, booked.Booking.ID).
		Scan(&status, &cancelledBy, &reason); err != nil {
		t.Fatal(err)
	}
	if status != "cancelled" {
		t.Errorf("expected cancelled, got %q", status)
	}
	if cancelledBy != "school" {
		t.Errorf("expected cancelled_by school, got %q", cancelledBy)
	}
	if reason == "" {
		t.Errorf("expected a reason auto-filled")
	}
}

func TestDisruption_DoubleResolveRejected(t *testing.T) {
	f := newFixture(t)
	addA1Bike(t, f, "bike_a1_spare")
	booked, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA})
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	disrupt := takeOffline(t, f, booked.Booking.BikeID, 0)

	resReq := booking.ResolveAffectedBookingRequest{
		DisruptionID: disrupt.DisruptionID,
		BookingID:    booked.Booking.ID,
		Resolution:   booking.ResolveSwap,
		NewBikeID:    "bike_a1_spare",
		ApprovedBy:   f.instructor,
	}
	if err := booking.ResolveAffectedBooking(context.Background(), f.scope, resReq); err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	err = booking.ResolveAffectedBooking(context.Background(), f.scope, resReq)
	if !errors.Is(err, booking.ErrAlreadyResolved) {
		t.Fatalf("expected ErrAlreadyResolved, got %v", err)
	}
}

func TestDisruption_BikeNotFound(t *testing.T) {
	f := newFixture(t)
	_, err := booking.TakeBikeOffline(context.Background(), f.scope,
		booking.TakeBikeOfflineRequest{
			BikeID:    "nope",
			Reason:    "broken",
			StartsAt:  f.now,
			EndsAt:    f.now.Add(24 * time.Hour),
			CreatedBy: f.instructor,
		})
	if !errors.Is(err, booking.ErrBikeNotFound) {
		t.Fatalf("expected ErrBikeNotFound, got %v", err)
	}
}

func TestDisruption_TenantIsolation(t *testing.T) {
	f := newFixture(t)
	other := tenant.NewScope(f.db, domain.SchoolID("school_other"))
	_, err := booking.TakeBikeOffline(context.Background(), other,
		booking.TakeBikeOfflineRequest{
			BikeID:    f.bikeA1,
			Reason:    "broken",
			StartsAt:  f.now,
			EndsAt:    f.now.Add(24 * time.Hour),
			CreatedBy: f.instructor,
		})
	if !errors.Is(err, booking.ErrBikeNotFound) {
		t.Fatalf("expected ErrBikeNotFound (tenant-isolated), got %v", err)
	}
}

func TestDisruption_InvalidWindow(t *testing.T) {
	f := newFixture(t)
	_, err := booking.TakeBikeOffline(context.Background(), f.scope,
		booking.TakeBikeOfflineRequest{
			BikeID:    f.bikeA1,
			Reason:    "broken",
			StartsAt:  f.now.Add(24 * time.Hour),
			EndsAt:    f.now, // end before start
			CreatedBy: f.instructor,
		})
	if !errors.Is(err, booking.ErrInvalidWindow) {
		t.Fatalf("expected ErrInvalidWindow, got %v", err)
	}
}

func TestDisruption_OffersOnlyFutureBookings(t *testing.T) {
	// Take a bike offline starting tomorrow morning. A booking on this bike
	// for *today* (or any past session) shouldn't be affected.
	// In our fixture the only session is 24h in the future, so taking the
	// bike offline starting 48h forward shouldn't catch it.
	f := newFixture(t)
	if _, err := f.book(booking.Request{SessionID: f.sessionID, StudentID: f.studentA}); err != nil {
		t.Fatalf("book: %v", err)
	}
	res := takeOffline(t, f, f.bikeA1, 48) // starts 48h from now; session is at +24h
	if len(res.AffectedBookings) != 0 {
		t.Errorf("expected 0 affected (window is after session), got %d", len(res.AffectedBookings))
	}
}
