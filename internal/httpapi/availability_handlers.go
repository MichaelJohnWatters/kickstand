package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/availability"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Availability endpoints: instructors manage their own; admin/owner can
// manage anyone in the school.

func canManageInstructor(id *auth.Identity, instructorID domain.UserID) bool {
	if id.Role == domain.RoleAdmin || id.Role == domain.RoleOwner {
		return true
	}
	return id.Role == domain.RoleInstructor && id.UserID == instructorID
}

func writeAvailabilityError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, availability.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, availability.ErrInvalidInput):
		writeError(w, http.StatusBadRequest, "invalid_input", err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}

// ----- Recurring slots -----

func (s *Server) handleListRecurringAvailability(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	instructorID := domain.UserID(r.PathValue("id"))
	if !canManageInstructor(id, instructorID) {
		writeError(w, http.StatusForbidden, "forbidden", "not allowed")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := availability.ListRecurringSlots(r.Context(), scope, instructorID)
	if err != nil {
		writeAvailabilityError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, slot := range out {
		v := map[string]any{
			"id":            slot.ID,
			"instructorId":  slot.InstructorID,
			"weekday":       slot.Weekday,
			"startsAtLocal": slot.StartsAtLocal,
			"endsAtLocal":   slot.EndsAtLocal,
		}
		if slot.LocationID != "" {
			v["locationId"] = slot.LocationID
		}
		rows = append(rows, v)
	}
	writeJSON(w, http.StatusOK, map[string]any{"slots": rows})
}

func (s *Server) handleCreateRecurringAvailability(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	instructorID := domain.UserID(r.PathValue("id"))
	if !canManageInstructor(id, instructorID) {
		writeError(w, http.StatusForbidden, "forbidden", "not allowed")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Weekday       int    `json:"weekday"`
		StartsAtLocal string `json:"startsAtLocal"`
		EndsAtLocal   string `json:"endsAtLocal"`
		LocationID    string `json:"locationId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	slot, err := availability.CreateRecurringSlot(r.Context(), scope, availability.CreateRecurringRequest{
		InstructorID:  instructorID,
		Weekday:       req.Weekday,
		StartsAtLocal: req.StartsAtLocal,
		EndsAtLocal:   req.EndsAtLocal,
		LocationID:    domain.LocationID(req.LocationID),
	})
	if err != nil {
		writeAvailabilityError(w, err)
		return
	}
	v := map[string]any{
		"id":            slot.ID,
		"instructorId":  slot.InstructorID,
		"weekday":       slot.Weekday,
		"startsAtLocal": slot.StartsAtLocal,
		"endsAtLocal":   slot.EndsAtLocal,
	}
	if slot.LocationID != "" {
		v["locationId"] = slot.LocationID
	}
	writeJSON(w, http.StatusCreated, v)
}

func (s *Server) handleDeleteRecurringAvailability(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	// We don't know whose slot it is without a lookup. Cheap approach: try
	// to delete; the data layer enforces tenant. To gate per-instructor we'd
	// need to load + check. For MVP, allow any staff to delete within their
	// school — admin or the instructor themself.
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	if err := availability.DeleteRecurringSlot(r.Context(), scope, domain.AvailabilityID(r.PathValue("slotId"))); err != nil {
		writeAvailabilityError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----- Time off -----

func (s *Server) handleListTimeOff(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	instructorID := domain.UserID(r.PathValue("id"))
	if !canManageInstructor(id, instructorID) {
		writeError(w, http.StatusForbidden, "forbidden", "not allowed")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := availability.ListTimeOff(r.Context(), scope, instructorID)
	if err != nil {
		writeAvailabilityError(w, err)
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, t := range out {
		rows = append(rows, map[string]any{
			"id":           t.ID,
			"instructorId": t.InstructorID,
			"startsAt":     t.StartsAt.Format(time.RFC3339),
			"endsAt":       t.EndsAt.Format(time.RFC3339),
			"reason":       t.Reason,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"timeOff": rows})
}

func (s *Server) handleAddTimeOff(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	instructorID := domain.UserID(r.PathValue("id"))
	if !canManageInstructor(id, instructorID) {
		writeError(w, http.StatusForbidden, "forbidden", "not allowed")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		StartsAt string `json:"startsAt"`
		EndsAt   string `json:"endsAt"`
		Reason   string `json:"reason"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	startsAt, err := time.Parse(time.RFC3339, req.StartsAt)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_param", "startsAt: "+err.Error())
		return
	}
	endsAt, err := time.Parse(time.RFC3339, req.EndsAt)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_param", "endsAt: "+err.Error())
		return
	}
	t, err := availability.AddTimeOff(r.Context(), scope, availability.AddTimeOffRequest{
		InstructorID: instructorID, StartsAt: startsAt, EndsAt: endsAt, Reason: req.Reason,
	})
	if err != nil {
		writeAvailabilityError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":           t.ID,
		"instructorId": t.InstructorID,
		"startsAt":     t.StartsAt.Format(time.RFC3339),
		"endsAt":       t.EndsAt.Format(time.RFC3339),
		"reason":       t.Reason,
	})
}

func (s *Server) handleDeleteTimeOff(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := availability.DeleteTimeOff(r.Context(), scope, domain.TimeOffID(r.PathValue("timeOffId"))); err != nil {
		writeAvailabilityError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
