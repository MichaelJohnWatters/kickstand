package httpapi

import (
	"errors"
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/signup"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// ----- Public -----

func (s *Server) handleListSchools(w http.ResponseWriter, r *http.Request) {
	schools, err := signup.ListSchools(r.Context(), s.DB)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
		return
	}
	out := make([]map[string]any, 0, len(schools))
	for _, sc := range schools {
		// Dedicated single-tenant instance: advertise only its own school.
		if s.SingleTenantSchoolID != "" && string(sc.ID) != s.SingleTenantSchoolID {
			continue
		}
		out = append(out, map[string]any{
			"id":     sc.ID,
			"name":   sc.Name,
			"region": sc.Region,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"schools": out})
}

// ----- Admin: approval queue -----

func (s *Server) handleListPendingSignups(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	list, err := signup.ListPending(r.Context(), scope)
	if err != nil {
		writeSignupError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"applicants": applicantViews(list)})
}

// GET /signups/rejected — same shape as /signups/pending but pulls
// disabled-with-no-bookings users for the Rejected tab. Admin/owner.
func (s *Server) handleListRejectedSignups(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	list, err := signup.ListRejected(r.Context(), scope)
	if err != nil {
		writeSignupError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"applicants": applicantViews(list)})
}

// GET /signups/approved — recently-approved students (last 7 days) so
// the manager can still find the phone number after approving. Same
// shape as the other two endpoints, plus approvedAt for ordering.
func (s *Server) handleListApprovedSignups(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	list, err := signup.ListApproved(r.Context(), scope)
	if err != nil {
		writeSignupError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"applicants": applicantViews(list)})
}

func applicantViews(list []signup.PendingApplicant) []map[string]any {
	out := make([]map[string]any, 0, len(list))
	for _, p := range list {
		row := map[string]any{
			"userId":                 p.UserID,
			"name":                   p.Name,
			"email":                  p.Email,
			"phone":                  p.Phone,
			"licenceCategoryPursued": p.LicenceCategoryPursued,
			"dateOfBirth":            p.DateOfBirth,
			"transmissionPreference": p.TransmissionPreference,
			"signupNote":             p.SignupNote,
			"signedUpAt":             p.SignedUpAt,
		}
		if !p.ApprovedAt.IsZero() {
			row["approvedAt"] = p.ApprovedAt
		}
		out = append(out, row)
	}
	return out
}

func (s *Server) handleApproveSignup(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	applicantID := domain.UserID(r.PathValue("id"))
	var applicantName string
	_ = s.DB.QueryRowContext(r.Context(),
		`SELECT name FROM users WHERE id = ? AND school_id = ?`,
		string(applicantID), string(id.SchoolID)).Scan(&applicantName)
	if err := signup.Approve(r.Context(), scope, applicantID); err != nil {
		writeSignupError(w, err)
		return
	}
	if applicantName == "" {
		applicantName = string(applicantID)
	}
	audit.Describe(r.Context(), "Approved sign-up for %s", applicantName)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRejectSignup(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	applicantID := domain.UserID(r.PathValue("id"))
	var applicantName string
	_ = s.DB.QueryRowContext(r.Context(),
		`SELECT name FROM users WHERE id = ? AND school_id = ?`,
		string(applicantID), string(id.SchoolID)).Scan(&applicantName)
	if err := signup.Reject(r.Context(), scope, applicantID); err != nil {
		writeSignupError(w, err)
		return
	}
	if applicantName == "" {
		applicantName = string(applicantID)
	}
	audit.Describe(r.Context(), "Rejected sign-up for %s", applicantName)
	w.WriteHeader(http.StatusNoContent)
}

// POST /signups/{id}/restore — flips a rejected (disabled, no-bookings)
// student back to pending_approval so the admin can re-review them.
// Admin/owner.
func (s *Server) handleRestoreSignup(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	applicantID := domain.UserID(r.PathValue("id"))
	var applicantName string
	_ = s.DB.QueryRowContext(r.Context(),
		`SELECT name FROM users WHERE id = ? AND school_id = ?`,
		string(applicantID), string(id.SchoolID)).Scan(&applicantName)
	if err := signup.Restore(r.Context(), scope, applicantID); err != nil {
		writeSignupError(w, err)
		return
	}
	if applicantName == "" {
		applicantName = string(applicantID)
	}
	audit.Describe(r.Context(),
		"Restored sign-up for %s — back to pending review", applicantName)
	w.WriteHeader(http.StatusNoContent)
}

func writeSignupError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, signup.ErrSchoolNotFound):
		writeError(w, http.StatusNotFound, "school_not_found", err.Error())
	case errors.Is(err, signup.ErrEmailAlreadyInUse):
		writeError(w, http.StatusConflict, "email_in_use", err.Error())
	case errors.Is(err, signup.ErrInvalidEmail):
		writeError(w, http.StatusBadRequest, "invalid_email", err.Error())
	case errors.Is(err, signup.ErrMissingField):
		writeError(w, http.StatusBadRequest, "missing_field", err.Error())
	case errors.Is(err, signup.ErrInvalidField):
		writeError(w, http.StatusBadRequest, "invalid_field", err.Error())
	case errors.Is(err, signup.ErrPendingNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, signup.ErrNotPending):
		writeError(w, http.StatusConflict, "not_pending", err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}
