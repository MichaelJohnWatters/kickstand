package httpapi

import (
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/logistics"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

func (s *Server) handleLogistics(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)

	dateStr := r.URL.Query().Get("date")
	var day time.Time
	if dateStr == "" {
		// Default to tomorrow (the typical end-of-day question).
		day = time.Now().UTC().Add(24 * time.Hour)
	} else {
		t, err := time.Parse("2006-01-02", dateStr)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_param", "date: expected YYYY-MM-DD")
			return
		}
		day = t
	}

	sum, err := logistics.SummaryForDay(r.Context(), scope, day)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}

	dests := make([]map[string]any, 0, len(sum.Destinations))
	for _, d := range sum.Destinations {
		moves := make([]map[string]any, 0, len(d.Moves))
		for _, m := range d.Moves {
			moves = append(moves, map[string]any{
				"bikeId":           m.BikeID,
				"bikeNickname":     m.BikeNickname,
				"bikeCategory":     m.BikeCategory,
				"bikeRegistration": m.BikeRegistration,
				"fromLocationId":   m.FromLocationID,
				"fromLocationName": m.FromLocationName,
				"toLocationId":     m.ToLocationID,
				"toLocationName":   m.ToLocationName,
				"sessionId":        m.SessionID,
				"sessionStartsAt":  m.SessionStartsAt.Format(time.RFC3339),
				"courseTypeName":   m.CourseTypeName,
				"studentId":        m.StudentID,
				"studentName":      m.StudentName,
				"bookingId":        m.BookingID,
			})
		}
		dests = append(dests, map[string]any{
			"locationId":   d.LocationID,
			"locationName": d.LocationName,
			"moves":        moves,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"date":         sum.Date,
		"totalMoves":   sum.TotalMoves,
		"destinations": dests,
	})
}
