package httpapi

import (
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/calendar"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// handleCalendar serves the admin master-calendar payload. Staff-only.
//
// Query params:
//   from / to     RFC3339 window (required)
//   instructorId  optional filter
//   locationId    optional filter
//   courseTypeId  optional filter
func (s *Server) handleCalendar(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)

	from, err := parseTimeParam(r, "from", time.Now().UTC())
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_param", "from: "+err.Error())
		return
	}
	to, err := parseTimeParam(r, "to", from.Add(7*24*time.Hour))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_param", "to: "+err.Error())
		return
	}
	q := calendar.Query{
		From:             from,
		To:               to,
		InstructorID:     domain.UserID(r.URL.Query().Get("instructorId")),
		LocationID:       domain.LocationID(r.URL.Query().Get("locationId")),
		CourseTypeID:     domain.CourseTypeID(r.URL.Query().Get("courseTypeId")),
		IncludeCancelled: r.URL.Query().Get("includeCancelled") == "true",
	}

	// Instructors no longer get implicitly scoped to themselves —
	// the Mine/All toggle on the schedule screen now drives the
	// `instructorId` query param explicitly. (Tenant scope still
	// keeps cross-school traffic out.)
	_ = id // reserved for future per-role checks

	payload, err := calendar.Build(r.Context(), scope, q)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}

	sessions := make([]map[string]any, 0, len(payload.Sessions))
	for _, sr := range payload.Sessions {
		instructors := make([]map[string]any, 0, len(sr.Instructors))
		for _, ii := range sr.Instructors {
			instructors = append(instructors, map[string]any{
				"id":        ii.ID,
				"name":      ii.Name,
				"isPrimary": ii.IsPrimary,
			})
		}
		students := make([]map[string]any, 0, len(sr.Students))
		for _, st := range sr.Students {
			students = append(students, map[string]any{
				"id":           st.ID,
				"name":         st.Name,
				"status":       st.Status,
				"bookingId":    st.BookingID,
				"bikeId":       st.BikeID,
				"bikeNickname": st.BikeNickname,
			})
		}
		sessions = append(sessions, map[string]any{
			"sessionId":          sr.SessionID,
			"courseTypeId":       sr.CourseTypeID,
			"courseCode":         sr.CourseCode,
			"courseName":         sr.CourseName,
			"courseAccentColour": sr.CourseAccentColour,
			"nonTeaching":        sr.NonTeaching,
			"instructorId":       sr.InstructorID,
			"instructorName":     sr.InstructorName,
			"instructors":        instructors,
			"locationId":         sr.LocationID,
			"locationName":       sr.LocationName,
			"startsAt":           sr.StartsAt.Format(time.RFC3339),
			"endsAt":             sr.EndsAt.Format(time.RFC3339),
			"capacity":           sr.Capacity,
			"activeBookings":     sr.ActiveBookings,
			"students":           students,
			"status":             sr.Status,
		})
	}
	warnings := make([]map[string]any, 0, len(payload.Warnings))
	for _, wn := range payload.Warnings {
		warnings = append(warnings, map[string]any{
			"instructorId":     wn.InstructorID,
			"instructorName":   wn.InstructorName,
			"fromSessionId":    wn.FromSessionID,
			"toSessionId":      wn.ToSessionID,
			"fromLocationId":   wn.FromLocationID,
			"fromLocationName": wn.FromLocationName,
			"toLocationId":     wn.ToLocationID,
			"toLocationName":   wn.ToLocationName,
			"fromEndsAt":       wn.FromEndsAt.Format(time.RFC3339),
			"toStartsAt":       wn.ToStartsAt.Format(time.RFC3339),
			"gapMinutes":       wn.GapMinutes,
			"travelMinutes":    wn.TravelMinutes,
			"bufferMinutes":    wn.BufferMinutes,
			"message":          wn.Message,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"sessions": sessions,
		"warnings": warnings,
	})
}
