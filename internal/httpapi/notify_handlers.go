package httpapi

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/notify"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// GET /me/notifications?limit=&unread=true
//
// Returns the recent in-app notifications for the caller plus their
// unread count (used as the bell badge).
func (s *Server) handleListMyNotifications(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)

	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			limit = n
		}
	}
	unreadOnly := r.URL.Query().Get("unread") == "true"

	res, err := notify.List(r.Context(), scope, id.UserID, limit, unreadOnly)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}

	rows := make([]map[string]any, 0, len(res.Notifications))
	for _, n := range res.Notifications {
		row := map[string]any{
			"id":        n.ID,
			"eventId":   n.EventID,
			"eventKind": n.EventKind,
			"category":  n.Category,
			"status":    n.Status,
			"sentAt":    n.SentAt.Format(time.RFC3339),
			"payload":   n.Payload,
		}
		if !n.ReadAt.IsZero() {
			row["readAt"] = n.ReadAt.Format(time.RFC3339)
		}
		rows = append(rows, row)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"notifications": rows,
		"unreadCount":   res.UnreadCount,
	})
}

// POST /me/notifications/{id}/read
func (s *Server) handleMarkNotificationRead(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := notify.MarkRead(r.Context(), scope, id.UserID, domain.NotificationID(r.PathValue("id"))); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /me/notifications/read-all
func (s *Server) handleMarkAllNotificationsRead(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := notify.MarkAllRead(r.Context(), scope, id.UserID); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /me/device-tokens — register or refresh a device token. The Flutter
// client calls this on login + on token rotation (FCM tokens can change).
func (s *Server) handleRegisterDeviceToken(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		Token    string `json:"token"`
		Platform string `json:"platform"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := notify.RegisterDevice(r.Context(), scope, notify.RegisterDeviceRequest{
		UserID: id.UserID, SchoolID: id.SchoolID, Token: req.Token, Platform: req.Platform,
	}); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_input", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// DELETE /me/device-tokens/{token} — unregister on explicit logout.
func (s *Server) handleUnregisterDeviceToken(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := notify.UnregisterDevice(r.Context(), scope, r.PathValue("token")); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
