package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/notify"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// handleGetNotificationPrefs returns the caller's per-category prefs.
// Missing rows get filled with defaults — the response always has
// exactly one entry per canonical category.
func (s *Server) handleGetNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	prefs, err := notify.GetPrefs(r.Context(), scope, id.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "prefs_failed", err.Error())
		return
	}
	out := make([]map[string]any, 0, len(prefs))
	for _, p := range prefs {
		out = append(out, map[string]any{
			"category": p.Category,
			"inApp":    p.InApp,
			"email":    p.Email,
			"push":     p.Push,
			"sms":      p.SMS,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"prefs": out})
}

// handlePutNotificationPrefs upserts the caller's prefs. Body is the
// same shape as the GET response. Unknown categories return 400.
func (s *Server) handlePutNotificationPrefs(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var body struct {
		Prefs []struct {
			Category string `json:"category"`
			InApp    bool   `json:"inApp"`
			Email    bool   `json:"email"`
			Push     bool   `json:"push"`
			SMS      bool   `json:"sms"`
		} `json:"prefs"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	prefs := make([]notify.CategoryPrefs, 0, len(body.Prefs))
	for _, p := range body.Prefs {
		prefs = append(prefs, notify.CategoryPrefs{
			Category: p.Category,
			InApp:    p.InApp,
			Email:    p.Email,
			Push:     p.Push,
			SMS:      p.SMS,
		})
	}
	if err := notify.SetPrefs(r.Context(), scope, id.UserID, prefs); err != nil {
		writeError(w, http.StatusBadRequest, "prefs_failed", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
