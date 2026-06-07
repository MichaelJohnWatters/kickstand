package httpapi

import (
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// GET /disruptions?status=open|all
//
// Lists disruptions with their affected bookings. For 'pending' affected
// rows we compute live swap candidates so the resolution UI can show what
// bikes are currently free.
//
// Staff-only.
func (s *Server) handleListDisruptions(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	openOnly := r.URL.Query().Get("status") != "all"

	rows, err := booking.ListDisruptions(r.Context(), scope, openOnly)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}

	out := make([]map[string]any, 0, len(rows))
	for _, d := range rows {
		affected := make([]map[string]any, 0, len(d.Affected))
		for _, ab := range d.Affected {
			swaps := make([]map[string]any, 0, len(ab.SwapCandidates))
			for _, c := range ab.SwapCandidates {
				swaps = append(swaps, map[string]any{
					"bikeId":            c.BikeID,
					"bikeNickname":      c.BikeNickname,
					"bikeRegistration":  c.BikeRegistration,
					"currentLocationId": c.CurrentLocationID,
					"isCrossSite":       c.IsCrossSite,
				})
			}
			row := map[string]any{
				"bookingId":       ab.BookingID,
				"sessionId":       ab.SessionID,
				"courseName":      ab.CourseName,
				"sessionStartsAt": ab.SessionStartsAt.Format(time.RFC3339),
				"sessionEndsAt":   ab.SessionEndsAt.Format(time.RFC3339),
				"studentId":       ab.StudentID,
				"studentName":     ab.StudentName,
				"locationId":      ab.LocationID,
				"locationName":    ab.LocationName,
				"resolution":      ab.Resolution,
				"swapCandidates":  swaps,
			}
			if ab.NewBikeID != "" {
				row["newBikeId"] = ab.NewBikeID
				row["newBikeNickname"] = ab.NewBikeNickname
			}
			if !ab.ResolvedAt.IsZero() {
				row["resolvedAt"] = ab.ResolvedAt.Format(time.RFC3339)
			}
			affected = append(affected, row)
		}
		dv := map[string]any{
			"disruptionId":     d.ID,
			"bikeId":           d.BikeID,
			"bikeNickname":     d.BikeNickname,
			"bikeRegistration": d.BikeRegistration,
			"reason":           d.Reason,
			"startedAt":        d.StartedAt.Format(time.RFC3339),
			"reportedByName":   d.ReportedByName,
			"locationId":       d.LocationID,
			"locationName":     d.LocationName,
			"affectedBookings": affected,
		}
		if !d.ResolvedAt.IsZero() {
			dv["resolvedAt"] = d.ResolvedAt.Format(time.RFC3339)
		}
		out = append(out, dv)
	}
	writeJSON(w, http.StatusOK, map[string]any{"disruptions": out})
}
