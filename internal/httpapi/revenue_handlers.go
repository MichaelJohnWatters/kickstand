package httpapi

import (
	"net/http"
	"strconv"

	"github.com/michaeljohnwatters/kickstand/internal/revenue"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// GET /revenue?months=12 — admin/owner-only revenue overview.
// Returns three blocks in one payload so the dashboard renders without
// a fan-out: monthly buckets, ageing, per-course breakdown.
func (s *Server) handleGetRevenue(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)

	months, _ := strconv.Atoi(r.URL.Query().Get("months"))
	monthly, err := revenue.Monthly(r.Context(), scope, months)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	ageing, err := revenue.Ageing(r.Context(), scope)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	byCourse, err := revenue.ByCourse(r.Context(), scope)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}

	monthOut := make([]map[string]any, 0, len(monthly.Buckets))
	for _, b := range monthly.Buckets {
		monthOut = append(monthOut, map[string]any{
			"month":          b.Month,
			"billedPence":    b.BilledPence,
			"collectedPence": b.CollectedPence,
		})
	}
	ageingOut := make([]map[string]any, 0, len(ageing))
	for _, b := range ageing {
		ageingOut = append(ageingOut, map[string]any{
			"label": b.Label,
			"pence": b.Pence,
		})
	}
	byCourseOut := make([]map[string]any, 0, len(byCourse))
	for _, b := range byCourse {
		byCourseOut = append(byCourseOut, map[string]any{
			"courseTypeId": b.CourseTypeID,
			"code":         b.Code,
			"name":         b.Name,
			"bookingCount": b.BookingCount,
			"billedPence":  b.BilledPence,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"monthly": map[string]any{
			"buckets":          monthOut,
			"outstandingPence": monthly.OutstandingPence,
		},
		"ageing":   ageingOut,
		"byCourse": byCourseOut,
	})
}
