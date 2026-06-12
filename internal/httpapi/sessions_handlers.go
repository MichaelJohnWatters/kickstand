package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/admin"
	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// POST /sessions — ad-hoc session create. Admin/owner only.
// Instructors is 0..N; an empty list means "scaffold now, assign later".
//
// Response includes any soft RatioWarning so the UI can surface
// "1:6 booked but 1:2 recommended" without the create being refused.
func (s *Server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		CourseTypeID  string   `json:"courseTypeId"`
		LocationID    string   `json:"locationId"`
		StartsAt      string   `json:"startsAt"`
		EndsAt        string   `json:"endsAt"`
		Capacity      int      `json:"capacity"`
		InstructorIDs []string `json:"instructorIds"`
		Notes         string   `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	startsAt, err := time.Parse(time.RFC3339, req.StartsAt)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_input", "startsAt must be RFC3339")
		return
	}
	endsAt, err := time.Parse(time.RFC3339, req.EndsAt)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_input", "endsAt must be RFC3339")
		return
	}
	instructorIDs := make([]domain.UserID, 0, len(req.InstructorIDs))
	for _, iid := range req.InstructorIDs {
		instructorIDs = append(instructorIDs, domain.UserID(iid))
	}
	res, err := admin.CreateSession(r.Context(), scope, admin.CreateSessionRequest{
		CourseTypeID:  domain.CourseTypeID(req.CourseTypeID),
		LocationID:    domain.LocationID(req.LocationID),
		StartsAt:      startsAt,
		EndsAt:        endsAt,
		Capacity:      req.Capacity,
		InstructorIDs: instructorIDs,
		Notes:         req.Notes,
		CreatedBy:     id.UserID,
	})
	if err != nil {
		writeAdminError(w, err)
		return
	}
	warnings := make([]map[string]any, 0, len(res.Warnings))
	for _, wn := range res.Warnings {
		warnings = append(warnings, map[string]any{
			"message":                wn.Message,
			"studentsPerInstructor":  wn.StudentsPerInstructor,
			"recommendedMax":         wn.RecommendedMax,
		})
	}
	audit.Describe(r.Context(),
		"Scheduled a session on %s with %d instructor%s, capacity %d",
		startsAt.Format("2006-01-02"),
		len(instructorIDs), plural(len(instructorIDs)), req.Capacity)
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":       res.SessionID,
		"warnings": warnings,
	})
}

// PATCH /sessions/{id} — apply a partial patch (time window, capacity,
// or both) to an existing session. Admin/owner only. The calendar's
// drag-and-drop sends startsAt + endsAt; the edit sheet may send any
// subset. Course type, location and instructor assignment have their
// own dedicated endpoints (POST /sessions, PUT /sessions/{id}/instructors).
func (s *Server) handleUpdateSession(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		StartsAt *string `json:"startsAt,omitempty"`
		EndsAt   *string `json:"endsAt,omitempty"`
		Capacity *int    `json:"capacity,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	patch := admin.UpdateSessionRequest{Capacity: req.Capacity}
	if req.StartsAt != nil {
		t, err := time.Parse(time.RFC3339, *req.StartsAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_input", "startsAt must be RFC3339")
			return
		}
		patch.StartsAt = &t
	}
	if req.EndsAt != nil {
		t, err := time.Parse(time.RFC3339, *req.EndsAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_input", "endsAt must be RFC3339")
			return
		}
		patch.EndsAt = &t
	}
	sessionID := domain.SessionID(r.PathValue("id"))
	if err := admin.UpdateSession(r.Context(), scope, sessionID, patch); err != nil {
		if errors.Is(err, admin.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "session not found")
			return
		}
		writeAdminError(w, err)
		return
	}
	// Audit message tailored to which fields actually moved so the
	// log doesn't end up with vague "updated a session" rows.
	switch {
	case patch.StartsAt != nil && patch.Capacity != nil:
		audit.Describe(r.Context(),
			"Updated a session — moved to %s, capacity %d",
			patch.StartsAt.Format("2006-01-02 15:04"), *patch.Capacity)
	case patch.StartsAt != nil:
		audit.Describe(r.Context(),
			"Moved a session to %s", patch.StartsAt.Format("2006-01-02 15:04"))
	case patch.Capacity != nil:
		audit.Describe(r.Context(),
			"Set session capacity to %d", *patch.Capacity)
	}
	w.WriteHeader(http.StatusNoContent)
}

// PUT /sessions/{id}/instructors — replace the instructor assignment.
// Empty list clears the session ("needs instructor" state).
func (s *Server) handleSetSessionInstructors(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		InstructorIDs []string `json:"instructorIds"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	ids := make([]domain.UserID, 0, len(req.InstructorIDs))
	for _, iid := range req.InstructorIDs {
		ids = append(ids, domain.UserID(iid))
	}
	sessionID := domain.SessionID(r.PathValue("id"))
	if err := admin.SetSessionInstructors(r.Context(), scope, sessionID, ids, id.UserID); err != nil {
		if errors.Is(err, admin.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", err.Error())
			return
		}
		writeAdminError(w, err)
		return
	}
	if len(ids) == 0 {
		audit.Describe(r.Context(), "Cleared the instructor assignment for a session")
	} else {
		audit.Describe(r.Context(),
			"Assigned %d instructor%s to a session",
			len(ids), plural(len(ids)))
	}
	w.WriteHeader(http.StatusNoContent)
}

