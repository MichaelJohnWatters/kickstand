package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/progress"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Permissions for progress capture:
//   - Mark attendance, assess competency, set notes: the instructor assigned
//     to the session, OR admin/owner.
//   - View session detail: same — staff only, instructor must be assigned.
//   - View student progress: the student themselves, OR any staff.
//
// "Instructor on this session" is enforced via progress.IsInstructorForBooking
// which avoids leaking other instructors' sessions.

// ----- helpers -----

func canActOnBooking(ctx context.Context, scope *tenant.Scope,
	id *auth.Identity, bookingID domain.BookingID) (bool, error) {
	// Admin/owner: always.
	if id.Role == domain.RoleAdmin || id.Role == domain.RoleOwner {
		return true, nil
	}
	if id.Role != domain.RoleInstructor {
		return false, nil
	}
	// Instructor: must be the one assigned to this booking's session.
	return progress.IsInstructorForBooking(ctx, scope, bookingID, id.UserID)
}

func writeProgressError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, progress.ErrBookingNotFound),
		errors.Is(err, progress.ErrSessionNotFound),
		errors.Is(err, progress.ErrStudentNotFound),
		errors.Is(err, progress.ErrCompetencyNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, progress.ErrBookingNotInProgress):
		writeError(w, http.StatusConflict, "not_in_progress", err.Error())
	case errors.Is(err, progress.ErrInvalidAttendance), errors.Is(err, progress.ErrInvalidStatus):
		writeError(w, http.StatusBadRequest, "invalid_status", err.Error())
	case errors.Is(err, progress.ErrNonTeachingSession):
		writeError(w, http.StatusConflict, "non_teaching", err.Error())
	case errors.Is(err, progress.ErrCompetencyWrongCourse):
		writeError(w, http.StatusBadRequest, "wrong_course", err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}

// ----- Attendance -----

func (s *Server) handleMarkAttendance(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	bookingID := domain.BookingID(r.PathValue("id"))

	ok, err := canActOnBooking(r.Context(), scope, id, bookingID)
	if err != nil {
		writeProgressError(w, err)
		return
	}
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden", "not your session")
		return
	}

	var req struct {
		Status string `json:"status"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := progress.MarkAttendance(r.Context(), scope, progress.MarkAttendanceRequest{
		BookingID: bookingID,
		Status:    domain.BookingStatus(req.Status),
	}); err != nil {
		writeProgressError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----- Competency assessment -----

func (s *Server) handleAssessCompetency(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	bookingID := domain.BookingID(r.PathValue("id"))
	compID := domain.CompetencyID(r.PathValue("compId"))

	ok, err := canActOnBooking(r.Context(), scope, id, bookingID)
	if err != nil {
		writeProgressError(w, err)
		return
	}
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden", "not your session")
		return
	}

	var req struct {
		Status string `json:"status"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	rec, err := progress.AssessCompetency(r.Context(), scope, progress.AssessCompetencyRequest{
		BookingID:    bookingID,
		CompetencyID: compID,
		Status:       req.Status,
		RecordedBy:   id.UserID,
	})
	if err != nil {
		writeProgressError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":           rec.ID,
		"bookingId":    rec.BookingID,
		"studentId":    rec.StudentID,
		"competencyId": rec.CompetencyID,
		"status":       rec.Status,
		"recordedAt":   rec.RecordedAt.Format(time.RFC3339),
		"recordedBy":   rec.RecordedBy,
	})
}

// ----- Booking notes -----

func (s *Server) handleSetBookingNotes(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	bookingID := domain.BookingID(r.PathValue("id"))

	ok, err := canActOnBooking(r.Context(), scope, id, bookingID)
	if err != nil {
		writeProgressError(w, err)
		return
	}
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden", "not your session")
		return
	}

	var req struct {
		Notes string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := progress.SetBookingNotes(r.Context(), scope, progress.SetBookingNotesRequest{
		BookingID: bookingID, Notes: req.Notes,
	}); err != nil {
		writeProgressError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----- Session detail -----

func (s *Server) handleGetSessionDetail(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	sd, err := progress.GetSessionDetail(r.Context(), scope, domain.SessionID(r.PathValue("id")))
	if err != nil {
		writeProgressError(w, err)
		return
	}
	// Instructors only see their own sessions.
	if id.Role == domain.RoleInstructor && sd.InstructorID != id.UserID {
		writeError(w, http.StatusForbidden, "forbidden", "not your session")
		return
	}
	writeJSON(w, http.StatusOK, sessionDetailView(sd))
}

func sessionDetailView(sd *progress.SessionDetail) map[string]any {
	bookings := make([]map[string]any, 0, len(sd.Bookings))
	for _, b := range sd.Bookings {
		flags := make([]map[string]any, 0, len(b.SafetyFlags))
		for _, f := range b.SafetyFlags {
			flags = append(flags, map[string]any{"id": f.ID, "body": f.Body})
		}
		comps := make(map[string]string, len(b.Competencies))
		for k, v := range b.Competencies {
			comps[string(k)] = v
		}
		bookings = append(bookings, map[string]any{
			"bookingId":        b.BookingID,
			"status":           b.Status,
			"bikeId":           b.BikeID,
			"bikeNickname":     b.BikeNickname,
			"studentId":        b.StudentID,
			"studentName":      b.StudentName,
			"studentPhone":     b.StudentPhone,
			"safetyFlags":      flags,
			"outstandingPence": b.OutstandingPence,
			"notes":            b.Notes,
			"competencies":     comps,
		})
	}
	tmpl := make([]map[string]any, 0, len(sd.CourseCompetencies))
	for _, c := range sd.CourseCompetencies {
		tmpl = append(tmpl, map[string]any{
			"id": c.ID, "label": c.Label, "sortOrder": c.SortOrder,
		})
	}
	return map[string]any{
		"sessionId":          sd.SessionID,
		"courseTypeId":       sd.CourseTypeID,
		"courseName":         sd.CourseName,
		"nonTeaching":        sd.NonTeaching,
		"instructorId":       sd.InstructorID,
		"instructorName":     sd.InstructorName,
		"locationId":         sd.LocationID,
		"locationName":       sd.LocationName,
		"startsAt":           sd.StartsAt.Format(time.RFC3339),
		"endsAt":             sd.EndsAt.Format(time.RFC3339),
		"capacity":           sd.Capacity,
		"status":             sd.Status,
		"bookings":           bookings,
		"courseCompetencies": tmpl,
	}
}

// ----- Student progress -----

func (s *Server) handleGetStudentProgress(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	studentID := domain.UserID(r.PathValue("id"))
	if id.Role == domain.RoleStudent && id.UserID != studentID {
		writeError(w, http.StatusForbidden, "forbidden", "students may only view their own progress")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	sp, err := progress.GetStudentProgress(r.Context(), scope, studentID)
	if err != nil {
		writeProgressError(w, err)
		return
	}
	courses := make([]map[string]any, 0, len(sp.Courses))
	for _, c := range sp.Courses {
		comps := make([]map[string]any, 0, len(c.Competencies))
		for _, cc := range c.Competencies {
			v := map[string]any{
				"competencyId": cc.CompetencyID,
				"label":        cc.Label,
				"status":       cc.Status,
			}
			if !cc.LastSeen.IsZero() {
				v["lastSeen"] = cc.LastSeen.Format(time.RFC3339)
			}
			comps = append(comps, v)
		}
		courses = append(courses, map[string]any{
			"courseTypeId":      c.CourseTypeID,
			"courseName":        c.CourseName,
			"totalCompetencies": c.TotalCompetencies,
			"competentCount":    c.CompetentCount,
			"needsWorkCount":    c.NeedsWorkCount,
			"competencies":      comps,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"studentId": sp.StudentID,
		"courses":   courses,
	})
}
