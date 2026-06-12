package httpapi

import (
	"context"
	"database/sql"
	"errors"
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/booking"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// POST /sessions/{id}/waitlist — student joins. Returns 409 +
// already_on_waitlist or not_full when the session isn't actually full.
func (s *Server) handleJoinWaitlist(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "students only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	e, err := booking.JoinWaitlist(r.Context(), scope,
		domain.SessionID(r.PathValue("id")), id.UserID)
	if err != nil {
		switch {
		case errors.Is(err, booking.ErrAlreadyOnWaitlist):
			writeError(w, http.StatusConflict, "already_on_waitlist", err.Error())
		case errors.Is(err, booking.ErrWaitlistNotApplicable):
			writeError(w, http.StatusConflict, "session_not_full", err.Error())
		case errors.Is(err, booking.ErrSessionNotFound):
			writeError(w, http.StatusNotFound, "not_found", err.Error())
		case errors.Is(err, booking.ErrSessionInPast),
			errors.Is(err, booking.ErrSessionNotBookable):
			writeError(w, http.StatusConflict, "not_bookable", err.Error())
		default:
			writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		}
		return
	}
	audit.Describe(r.Context(),
		"Joined waitlist for %s",
		sessionDisplayName(r.Context(), s.DB, id.SchoolID, e.SessionID))
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":        e.ID,
		"sessionId": e.SessionID,
		"joinedAt":  e.JoinedAt.UTC(),
	})
}

// sessionDisplayName fetches a session's course code + date for human
// audit summaries.
func sessionDisplayName(ctx context.Context, db *sql.DB, schoolID domain.SchoolID, sessionID domain.SessionID) string {
	var code, startsAt string
	if err := db.QueryRowContext(ctx, `
		SELECT COALESCE(ct.code, ''), s.starts_at
		FROM sessions s
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		WHERE s.id = ? AND s.school_id = ?
	`, string(sessionID), string(schoolID)).Scan(&code, &startsAt); err != nil {
		return string(sessionID)
	}
	if len(startsAt) >= 10 {
		startsAt = startsAt[:10]
	}
	if code == "" {
		return startsAt
	}
	return code + " · " + startsAt
}

// DELETE /sessions/{id}/waitlist — student leaves. Idempotent.
func (s *Server) handleLeaveWaitlist(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "students only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := booking.LeaveWaitlist(r.Context(), scope,
		domain.SessionID(r.PathValue("id")), id.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /sessions/{id}/waitlist — staff-only enumeration.
func (s *Server) handleListWaitlist(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := booking.ListWaitlist(r.Context(), scope,
		domain.SessionID(r.PathValue("id")))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, e := range out {
		rows = append(rows, map[string]any{
			"id":          e.ID,
			"studentId":   e.StudentID,
			"studentName": e.StudentName,
			"joinedAt":    e.JoinedAt.UTC(),
			"position":    e.Position,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"entries": rows,
		"count":   len(rows),
	})
}

// GET /me/waitlist — the student's own entries with their queue position.
func (s *Server) handleMyWaitlist(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "students only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := booking.MyWaitlistEntries(r.Context(), scope, id.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	rows := make([]map[string]any, 0, len(out))
	for _, e := range out {
		rows = append(rows, map[string]any{
			"id":        e.ID,
			"sessionId": e.SessionID,
			"joinedAt":  e.JoinedAt.UTC(),
			"position":  e.Position,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": rows})
}
