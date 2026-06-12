package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/closures"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// GET /closures — admin/owner list (newest first by from_date).
func (s *Server) handleListClosures(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := closures.List(r.Context(), scope)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, c := range out {
		rows = append(rows, map[string]any{
			"id":               c.ID,
			"fromDate":         c.FromDate,
			"toDate":           c.ToDate,
			"label":            c.Label,
			"reason":           c.Reason,
			"sessionsAffected": c.SessionsAffected,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"closures": rows})
}

// POST /closures — create a closure (single day or range).
func (s *Server) handleCreateClosure(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		FromDate string `json:"fromDate"`
		ToDate   string `json:"toDate"`
		Label    string `json:"label"`
		Reason   string `json:"reason"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	// Single-day shorthand: client only sends one date.
	if req.ToDate == "" {
		req.ToDate = req.FromDate
	}
	c, err := closures.Create(r.Context(), scope, closures.CreateRequest{
		FromDate:  req.FromDate,
		ToDate:    req.ToDate,
		Label:     req.Label,
		Reason:    req.Reason,
		CreatedBy: id.UserID,
	})
	if err != nil {
		if errors.Is(err, closures.ErrInvalidInput) {
			writeError(w, http.StatusBadRequest, "invalid_input", err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	if c.FromDate == c.ToDate {
		audit.Describe(r.Context(), "Added closure on %s — %s", c.FromDate, c.Label)
	} else {
		audit.Describe(r.Context(), "Added closure %s → %s — %s",
			c.FromDate, c.ToDate, c.Label)
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":       c.ID,
		"fromDate": c.FromDate,
		"toDate":   c.ToDate,
		"label":    c.Label,
		"reason":   c.Reason,
	})
}

// DELETE /closures/{id} — admin/owner remove.
func (s *Server) handleDeleteClosure(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := closures.Delete(r.Context(), scope, r.PathValue("id")); err != nil {
		if errors.Is(err, closures.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	audit.Describe(r.Context(), "Removed a closure")
	w.WriteHeader(http.StatusNoContent)
}
