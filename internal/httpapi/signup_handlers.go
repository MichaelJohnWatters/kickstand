package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

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
		out = append(out, map[string]any{
			"id":     sc.ID,
			"name":   sc.Name,
			"region": sc.Region,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"schools": out})
}

func (s *Server) handleSignup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SchoolID               string `json:"schoolId"`
		Name                   string `json:"name"`
		Email                  string `json:"email"`
		Phone                  string `json:"phone"`
		Password               string `json:"password"`
		TransmissionPreference string `json:"transmissionPreference"`
		LicenceCategoryPursued string `json:"licenceCategoryPursued"`
		DateOfBirth            string `json:"dateOfBirth"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	res, err := signup.Signup(r.Context(), s.DB, signup.SignupRequest{
		SchoolID:               domain.SchoolID(req.SchoolID),
		Name:                   req.Name,
		Email:                  req.Email,
		Phone:                  req.Phone,
		Password:               req.Password,
		TransmissionPreference: domain.Transmission(req.TransmissionPreference),
		LicenceCategoryPursued: domain.LicenceCategory(req.LicenceCategoryPursued),
		DateOfBirth:            req.DateOfBirth,
	})
	if err != nil {
		writeSignupError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"token":     res.Token,
		"expiresAt": res.ExpiresAt,
		"identity":  toIdentityView(res.Identity),
	})
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
	out := make([]map[string]any, 0, len(list))
	for _, p := range list {
		out = append(out, map[string]any{
			"userId":                 p.UserID,
			"name":                   p.Name,
			"email":                  p.Email,
			"phone":                  p.Phone,
			"licenceCategoryPursued": p.LicenceCategoryPursued,
			"dateOfBirth":            p.DateOfBirth,
			"transmissionPreference": p.TransmissionPreference,
			"signupNote":             p.SignupNote,
			"signedUpAt":             p.SignedUpAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"applicants": out})
}

func (s *Server) handleApproveSignup(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := signup.Approve(r.Context(), scope, domain.UserID(r.PathValue("id"))); err != nil {
		writeSignupError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRejectSignup(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleAdmin && id.Role != domain.RoleOwner {
		writeError(w, http.StatusForbidden, "forbidden", "admin/owner only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	if err := signup.Reject(r.Context(), scope, domain.UserID(r.PathValue("id"))); err != nil {
		writeSignupError(w, err)
		return
	}
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
	case errors.Is(err, signup.ErrPasswordTooShort):
		writeError(w, http.StatusBadRequest, "password_too_short", err.Error())
	case errors.Is(err, signup.ErrMissingField):
		writeError(w, http.StatusBadRequest, "missing_field", err.Error())
	case errors.Is(err, signup.ErrPendingNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, signup.ErrNotPending):
		writeError(w, http.StatusConflict, "not_pending", err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}
