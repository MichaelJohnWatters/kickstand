package httpapi

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type loginResponse struct {
	Token     string       `json:"token"`
	ExpiresAt time.Time    `json:"expiresAt"`
	Identity  identityView `json:"identity"`
}

type identityView struct {
	UserID        string `json:"userId"`
	SchoolID      string `json:"schoolId"`
	Role          string `json:"role"`
	AccountStatus string `json:"accountStatus"`
	Email         string `json:"email"`
	Name          string `json:"name"`
}

func toIdentityView(id auth.Identity) identityView {
	return identityView{
		UserID:        string(id.UserID),
		SchoolID:      string(id.SchoolID),
		Role:          string(id.Role),
		AccountStatus: string(id.AccountStatus),
		Email:         id.Email,
		Name:          id.Name,
	}
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", "request body must be valid JSON")
		return
	}
	if req.Email == "" || req.Password == "" {
		writeError(w, http.StatusBadRequest, "missing_field", "email and password are required")
		return
	}
	res, err := auth.Login(r.Context(), s.DB, auth.LoginRequest{
		Email:    req.Email,
		Password: req.Password,
	})
	if err != nil {
		writeEngineError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, loginResponse{
		Token:     string(res.Token),
		ExpiresAt: res.ExpiresAt,
		Identity:  toIdentityView(res.Identity),
	})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	tok, _ := bearerToken(r) // middleware already accepted it
	if err := auth.Logout(r.Context(), s.DB, domain.UserSessionToken(tok)); err != nil {
		writeEngineError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	id, ok := identityFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusInternalServerError, "no_identity", "auth middleware did not attach identity")
		return
	}
	writeJSON(w, http.StatusOK, toIdentityView(*id))
}
