package httpapi

import (
	"net/http"
	"strconv"

	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// GET /audit?actor=&entity=&targetId=&from=&to=&limit=&offset=
//
// Admin/owner only. Returns audit rows in `at DESC` order plus the
// total count for the same filter so the UI can drive pagination.
func (s *Server) handleListAudit(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	f := audit.Filter{
		ActorUserID:  domain.UserID(q.Get("actor")),
		TargetEntity: q.Get("entity"),
		TargetID:     q.Get("targetId"),
		From:         q.Get("from"),
		To:           q.Get("to"),
		Limit:        limit,
		Offset:       offset,
	}
	rows, total, err := audit.List(r.Context(), s.DB, id.SchoolID, f)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	out := make([]map[string]any, 0, len(rows))
	for _, ro := range rows {
		out = append(out, map[string]any{
			"id":           ro.ID,
			"at":           ro.At,
			"actorUserId":  ro.ActorUserID,
			"actorRole":    ro.ActorRole,
			"actorName":    ro.ActorName,
			"method":       ro.Method,
			"pathPattern":  ro.PathPattern,
			"targetEntity": ro.TargetEntity,
			"targetId":     ro.TargetID,
			"targetLabel":  ro.TargetLabel,
			"summary":      ro.Summary,
			"statusCode":   ro.StatusCode,
			"errorCode":    ro.ErrorCode,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"entries": out,
		"total":   total,
	})
}
