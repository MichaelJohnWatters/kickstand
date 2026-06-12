package httpapi

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/audit"
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
	bikeLabel := bikeDisplayName(r.Context(), s.DB, id.SchoolID, bikeID)
	affected := len(res.AffectedBookings)
	if affected == 0 {
		audit.Describe(r.Context(),
			"Took %s offline (reason: %s)", bikeLabel, req.Reason)
	} else {
		audit.Describe(r.Context(),
			"Took %s offline (reason: %s) — %d booking%s need reassignment",
			bikeLabel, req.Reason, affected, plural(affected))
	}
	writeJSON(w, http.StatusCreated, disruptionView(res))
}

// bikeDisplayName fetches a bike's nickname / make+model for human
// audit summaries. Falls back to the ID when the bike is gone (audit
// rows outlive their targets).
func bikeDisplayName(ctx context.Context, db *sql.DB, schoolID domain.SchoolID, bikeID domain.BikeID) string {
	var nickname, make, model string
	err := db.QueryRowContext(ctx, `
		SELECT COALESCE(nickname,''), COALESCE(make,''), COALESCE(model,'')
		FROM bikes WHERE id = ? AND school_id = ?
	`, string(bikeID), string(schoolID)).Scan(&nickname, &make, &model)
	if err != nil {
		return string(bikeID)
	}
	if nickname != "" {
		return nickname
	}
	combined := strings.TrimSpace(make + " " + model)
	if combined != "" {
		return combined
	}
	return string(bikeID)
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
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
	// Enrich the audit row with a human sentence. Without this the
	// audit log just shows the raw HTTP path — useless for the "why
	// was this booking cancelled?" forensic loop. Best-effort: a
	// query miss falls back to a generic message rather than blocking
	// the response (which has already done the real work).
	audit.Describe(r.Context(), "%s",
		resolveAuditMessage(r.Context(), s.DB, id.SchoolID,
			bookingID, req.Resolution, req.NewBikeID))
	w.WriteHeader(http.StatusNoContent)
}

func resolveAuditMessage(ctx context.Context, db *sql.DB, schoolID domain.SchoolID,
	bookingID domain.BookingID, resolution, newBikeID string) string {
	var (
		studentName, courseName, oldBikeNick string
	)
	_ = db.QueryRowContext(ctx, `
		SELECT COALESCE(u.name, ''), COALESCE(ct.name, ''),
		       COALESCE(bk.nickname, '')
		FROM bookings b
		JOIN sessions s     ON s.id = b.session_id     AND s.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN users u    ON u.id = b.student_id   AND u.school_id = b.school_id
		LEFT JOIN bikes bk   ON bk.id = b.bike_id     AND bk.school_id = b.school_id
		WHERE b.id = ? AND b.school_id = ?
	`, string(bookingID), string(schoolID)).
		Scan(&studentName, &courseName, &oldBikeNick)

	who := studentName
	if who == "" {
		who = "a student"
	}
	what := courseName
	if what == "" {
		what = "their booking"
	}
	switch resolution {
	case "swapped":
		var newNick string
		_ = db.QueryRowContext(ctx,
			`SELECT COALESCE(nickname, '') FROM bikes WHERE id = ? AND school_id = ?`,
			newBikeID, string(schoolID)).Scan(&newNick)
		switch {
		case oldBikeNick != "" && newNick != "":
			return fmt.Sprintf("Swapped %s → %s for %s's %s",
				oldBikeNick, newNick, who, what)
		case newNick != "":
			return fmt.Sprintf("Assigned %s to %s's %s", newNick, who, what)
		default:
			return fmt.Sprintf("Reassigned a bike on %s's %s", who, what)
		}
	case "dismissed":
		return fmt.Sprintf("Dismissed past-due disruption row for %s's %s", who, what)
	}
	return fmt.Sprintf("Cancelled %s's %s (no suitable swap)", who, what)
}

// POST /disruptions/dismiss-past — bulk cancel-with-approval for any
// affected booking still pending after its session ended. Admin/owner
// only. Returns `{cancelled: N}`.
func (s *Server) handleDismissPastDisruptions(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	res, err := booking.DismissPastPendingDisruptions(r.Context(), scope, id.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	if res.Cancelled > 0 {
		audit.Describe(r.Context(),
			"Dismissed %d past-due disruption row%s",
			res.Cancelled, plural(res.Cancelled))
	}
	writeJSON(w, http.StatusOK, map[string]any{"cancelled": res.Cancelled})
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
