package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/templates"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

var _weekdayNames = []string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}

// GET /session-templates — list (admin/owner).
func (s *Server) handleListTemplates(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := templates.List(r.Context(), scope)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"templates": templateRows(out),
	})
}

// POST /session-templates — create.
func (s *Server) handleCreateTemplate(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		CourseTypeID    string `json:"courseTypeId"`
		InstructorID    string `json:"instructorId"`
		LocationID      string `json:"locationId"`
		Weekday         int    `json:"weekday"`
		StartsAtTime    string `json:"startsAtTime"`
		DurationMinutes int    `json:"durationMinutes"`
		Capacity        int    `json:"capacity"`
		StartsOn        string `json:"startsOn"`
		EndsOn          string `json:"endsOn"`
		Notes           string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	t, err := templates.Create(r.Context(), scope, templates.CreateRequest{
		CourseTypeID:    domain.CourseTypeID(req.CourseTypeID),
		InstructorID:    domain.UserID(req.InstructorID),
		LocationID:      domain.LocationID(req.LocationID),
		Weekday:         req.Weekday,
		StartsAtTime:    req.StartsAtTime,
		DurationMinutes: req.DurationMinutes,
		Capacity:        req.Capacity,
		StartsOn:        req.StartsOn,
		EndsOn:          req.EndsOn,
		Notes:           req.Notes,
		CreatedBy:       id.UserID,
	})
	if err != nil {
		if errors.Is(err, templates.ErrInvalidInput) {
			writeError(w, http.StatusBadRequest, "invalid_input", err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	audit.Describe(r.Context(),
		"Created template — %s at %s, %ss %s, capacity %d",
		t.CourseCode, t.LocationName, _weekdayNames[t.Weekday],
		t.StartsAtTime, t.Capacity)
	writeJSON(w, http.StatusCreated, templateRow(*t))
}

// DELETE /session-templates/{id} — remove (existing sessions stay).
func (s *Server) handleDeleteTemplate(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := templates.Delete(r.Context(), scope, r.PathValue("id")); err != nil {
		if errors.Is(err, templates.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /session-templates/materialise?weeks=4 — generate concrete
// sessions for every template in the school over the next N weeks.
// Idempotent.
func (s *Server) handleMaterialiseTemplates(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	weeks, _ := strconv.Atoi(r.URL.Query().Get("weeks"))
	if weeks <= 0 || weeks > 26 {
		weeks = 4
	}
	now := time.Now().UTC()
	from := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	to := from.AddDate(0, 0, 7*weeks)
	res, err := templates.Materialise(r.Context(), scope, from, to, id.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	if res.CreatedCount == 0 {
		audit.Describe(r.Context(),
			"Ran template generation (%d week%s) — already up to date",
			weeks, plural(weeks))
	} else {
		audit.Describe(r.Context(),
			"Generated %d session%s from templates over the next %d week%s",
			res.CreatedCount, plural(res.CreatedCount),
			weeks, plural(weeks))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"materialisationId": res.MaterialisationID,
		"created":           res.CreatedCount,
		"window": map[string]any{
			"from": from.Format("2006-01-02"),
			"to":   to.Format("2006-01-02"),
		},
	})
}

// POST /session-templates/{id}/materialise?weeks=4 — generate concrete
// sessions for one template only. Same idempotency + history record
// as the all-templates variant.
func (s *Server) handleMaterialiseOneTemplate(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	weeks, _ := strconv.Atoi(r.URL.Query().Get("weeks"))
	if weeks <= 0 || weeks > 26 {
		weeks = 4
	}
	templateID := r.PathValue("id")
	now := time.Now().UTC()
	from := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	to := from.AddDate(0, 0, 7*weeks)
	res, err := templates.MaterialiseOne(r.Context(), scope, templateID, from, to, id.UserID)
	if err != nil {
		if errors.Is(err, templates.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	// Look up the template's course code for a tidy audit line.
	t, _ := templates.Get(r.Context(), scope, templateID)
	label := templateID
	if t != nil && t.CourseCode != "" {
		label = t.CourseCode
	}
	if res.CreatedCount == 0 {
		audit.Describe(r.Context(),
			"Ran %s template generation (%d week%s) — already up to date",
			label, weeks, plural(weeks))
	} else {
		audit.Describe(r.Context(),
			"Generated %d session%s from %s template over the next %d week%s",
			res.CreatedCount, plural(res.CreatedCount),
			label, weeks, plural(weeks))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"materialisationId": res.MaterialisationID,
		"created":           res.CreatedCount,
		"window": map[string]any{
			"from": from.Format("2006-01-02"),
			"to":   to.Format("2006-01-02"),
		},
	})
}

// GET /session-templates/materialisations — recent passes for the
// school, newest first. Powers the "Recent generations" list in the UI.
func (s *Server) handleListMaterialisations(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := templates.ListMaterialisations(r.Context(), scope)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, m := range out {
		row := map[string]any{
			"id":            m.ID,
			"at":            m.At,
			"performedBy":   m.PerformedBy,
			"performerName": m.PerformerName,
			"weeks":         m.Weeks,
			"windowFrom":    m.WindowFrom,
			"windowTo":      m.WindowTo,
			"createdCount":  m.CreatedCount,
			"undone":        !m.UndoneAt.IsZero(),
		}
		if !m.UndoneAt.IsZero() {
			row["undoneAt"] = m.UndoneAt
			row["undoneBy"] = m.UndoneBy
		}
		rows = append(rows, row)
	}
	writeJSON(w, http.StatusOK, map[string]any{"materialisations": rows})
}

// POST /session-templates/materialisations/{id}/undo — delete every
// session the pass generated (provided none are booked) and mark the
// pass undone. Refuses with 409 if bookings exist.
func (s *Server) handleUndoMaterialisation(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	deleted, err := templates.UndoMaterialisation(r.Context(), scope,
		r.PathValue("id"), id.UserID)
	if err != nil {
		switch {
		case errors.Is(err, templates.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found", err.Error())
		case errors.Is(err, templates.ErrAlreadyUndone):
			writeError(w, http.StatusConflict, "already_undone", err.Error())
		case errors.Is(err, templates.ErrUndoHasBookings):
			writeError(w, http.StatusConflict, "has_bookings",
				"some generated sessions already have bookings — cancel them first")
		default:
			writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		}
		return
	}
	audit.Describe(r.Context(),
		"Undid a template generation — deleted %d session%s",
		deleted, plural(deleted))
	writeJSON(w, http.StatusOK, map[string]any{"deleted": deleted})
}

// GET /session-templates/{id}/preview?weeks=4 — count NEW sessions a
// materialise would create.
func (s *Server) handlePreviewTemplate(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	weeks, _ := strconv.Atoi(r.URL.Query().Get("weeks"))
	if weeks <= 0 || weeks > 26 {
		weeks = 4
	}
	now := time.Now().UTC()
	from := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	to := from.AddDate(0, 0, 7*weeks)
	n, err := templates.Preview(r.Context(), scope, r.PathValue("id"), from, to)
	if err != nil {
		if errors.Is(err, templates.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"newSessions": n})
}

// ----- helpers -----

func templateRows(in []templates.Template) []map[string]any {
	out := make([]map[string]any, 0, len(in))
	for _, t := range in {
		out = append(out, templateRow(t))
	}
	return out
}

func templateRow(t templates.Template) map[string]any {
	return map[string]any{
		"id":              t.ID,
		"courseTypeId":    t.CourseTypeID,
		"courseCode":      t.CourseCode,
		"courseName":      t.CourseName,
		"instructorId":    t.InstructorID,
		"instructorName":  t.InstructorName,
		"locationId":      t.LocationID,
		"locationName":    t.LocationName,
		"weekday":         t.Weekday,
		"startsAtTime":    t.StartsAtTime,
		"durationMinutes": t.DurationMinutes,
		"capacity":        t.Capacity,
		"startsOn":        t.StartsOn,
		"endsOn":          t.EndsOn,
		"notes":           t.Notes,
	}
}
