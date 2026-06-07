package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Disruption flow (plan §6) is admin/instructor — both can take a bike
// offline in the field. Resolution (swap or cancel-with-approval) is
// admin-only since it changes student bookings.

func (s *Server) handleTakeBikeOffline(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "students cannot take bikes offline")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	bikeID := domain.BikeID(r.PathValue("id"))

	var req struct {
		Reason   string `json:"reason"`
		StartsAt string `json:"startsAt"` // optional; defaults to "now"
		EndsAt   string `json:"endsAt"`   // optional; defaults to far-future
		Notes    string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	startsAt := time.Now().UTC()
	if req.StartsAt != "" {
		t, err := time.Parse(time.RFC3339, req.StartsAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_param", "startsAt: "+err.Error())
			return
		}
		startsAt = t
	}
	endsAt := startsAt.AddDate(1, 0, 0) // ~indefinite
	if req.EndsAt != "" {
		t, err := time.Parse(time.RFC3339, req.EndsAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_param", "endsAt: "+err.Error())
			return
		}
		endsAt = t
	}

	res, err := booking.TakeBikeOffline(r.Context(), scope, booking.TakeBikeOfflineRequest{
		BikeID:    bikeID,
		Reason:    req.Reason,
		StartsAt:  startsAt,
		EndsAt:    endsAt,
		Notes:     req.Notes,
		CreatedBy: id.UserID,
	})
	if err != nil {
		writeDisruptionError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, disruptionView(res))
}

func (s *Server) handleResolveDisruption(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "only admin/owner can resolve disruptions")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	disruptionID := domain.DisruptionID(r.PathValue("disruptionId"))
	bookingID := domain.BookingID(r.PathValue("bookingId"))

	var req struct {
		Resolution string `json:"resolution"` // 'swapped' | 'cancel_with_approval'
		NewBikeID  string `json:"newBikeId"`  // required for 'swapped'
		Notes      string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	err := booking.ResolveAffectedBooking(r.Context(), scope, booking.ResolveAffectedBookingRequest{
		DisruptionID: disruptionID,
		BookingID:    bookingID,
		Resolution:   booking.ResolutionKind(req.Resolution),
		NewBikeID:    domain.BikeID(req.NewBikeID),
		ApprovedBy:   id.UserID,
		Notes:        req.Notes,
	})
	if err != nil {
		writeDisruptionError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func disruptionView(r *booking.TakeBikeOfflineResult) map[string]any {
	affected := make([]map[string]any, 0, len(r.AffectedBookings))
	for _, ab := range r.AffectedBookings {
		swaps := make([]map[string]any, 0, len(ab.SwapCandidates))
		for _, c := range ab.SwapCandidates {
			swaps = append(swaps, map[string]any{
				"bikeId":            c.BikeID,
				"currentLocationId": c.CurrentLocationID,
				"isCrossSite":       c.IsCrossSite,
			})
		}
		affected = append(affected, map[string]any{
			"bookingId":       ab.BookingID,
			"sessionId":       ab.SessionID,
			"studentId":       ab.StudentID,
			"sessionStartsAt": ab.SessionStartsAt.Format(time.RFC3339),
			"sessionEndsAt":   ab.SessionEndsAt.Format(time.RFC3339),
			"swapCandidates":  swaps,
		})
	}
	return map[string]any{
		"disruptionId":     r.DisruptionID,
		"affectedBookings": affected,
	}
}

func writeDisruptionError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, booking.ErrBikeNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, booking.ErrInvalidWindow):
		writeError(w, http.StatusBadRequest, "bad_window", err.Error())
	case errors.Is(err, booking.ErrDisruptionNotFound), errors.Is(err, booking.ErrNotAffectedByThis):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, booking.ErrSwapBikeNotSuitable):
		writeError(w, http.StatusConflict, "bike_not_suitable", err.Error())
	case errors.Is(err, booking.ErrAlreadyResolved):
		writeError(w, http.StatusConflict, "already_resolved", err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}
