package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/compliance"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// GET /compliance — admin/owner-only compliance dashboard payload.
// One aggregated response covering bikes (MOT + tax), instructors
// (accreditation), and the school (insurance), with per-row severity
// buckets + a summary tally so the screen renders without re-walking.
func (s *Server) handleGetCompliance(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	rep, err := compliance.Load(r.Context(), scope)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	bikes := make([]map[string]any, 0, len(rep.Bikes))
	for _, b := range rep.Bikes {
		bikes = append(bikes, map[string]any{
			"id":           b.ID,
			"nickname":     b.Nickname,
			"registration": b.Registration,
			"motExpiresOn": b.MOTExpiresOn,
			"motStatus":    b.MOTStatus,
			"taxExpiresOn": b.TaxExpiresOn,
			"taxStatus":    b.TaxStatus,
			"worstStatus":  b.WorstStatus,
		})
	}
	instructors := make([]map[string]any, 0, len(rep.Instructors))
	for _, i := range rep.Instructors {
		accs := make([]map[string]any, 0, len(i.Accreditations))
		for _, a := range i.Accreditations {
			accs = append(accs, map[string]any{
				"courseTypeId": a.CourseTypeID,
				"courseCode":   a.CourseCode,
				"courseName":   a.CourseName,
				"expiresOn":    a.ExpiresOn,
				"status":       a.Status,
			})
		}
		instructors = append(instructors, map[string]any{
			"userId":         i.UserID,
			"name":           i.Name,
			"accreditations": accs,
			"worstStatus":    i.WorstStatus,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"bikes":       bikes,
		"instructors": instructors,
		"school": map[string]any{
			"insuranceExpiresOn": rep.School.InsuranceExpiresOn,
			"insuranceStatus":    rep.School.InsuranceStatus,
		},
		"counts": rep.Counts,
	})
}

// PUT /school/insurance — set or clear the school's insurance expiry.
func (s *Server) handleSetInsurance(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, id) {
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	var req struct {
		ExpiresOn string `json:"expiresOn"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	if err := compliance.SetInsurance(r.Context(), scope, req.ExpiresOn); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_input", err.Error())
		return
	}
	if req.ExpiresOn == "" {
		audit.Describe(r.Context(), "Cleared school insurance expiry")
	} else {
		audit.Describe(r.Context(),
			"Set school insurance expiry to %s", req.ExpiresOn)
	}
	w.WriteHeader(http.StatusNoContent)
}
