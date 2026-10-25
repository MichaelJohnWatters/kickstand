package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/email"
	"github.com/michaeljohnwatters/kickstand/internal/signup"
)

// firstName returns the greeting name ("there" if blank).
func firstName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "there"
	}
	if i := strings.IndexByte(name, ' '); i > 0 {
		return name[:i]
	}
	return name
}

// accessTTL is how long a hand-rolled access token is valid. Longer than ideal
// until a refresh endpoint lands (Phase 1c); revocation still works because the
// middleware re-loads (and can reject) the user from the DB each request.
const accessTTL = 24 * time.Hour

// identityView is the wire shape of an authenticated identity. Both /me
// and the signup endpoints emit this. Kept as a plain JSON struct so
// the response is stable across the legacy + Firebase paths.
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

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	id, ok := identityFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusInternalServerError, "no_identity", "auth middleware did not attach identity")
		return
	}
	writeJSON(w, http.StatusOK, toIdentityView(*id))
}

// handleLogin — POST /auth/login (public). Verifies email + password and
// returns an access token + the identity. On a single-tenant instance the
// school is pinned; otherwise the client supplies schoolId (as at signup).
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if s.Tokens == nil {
		writeError(w, http.StatusServiceUnavailable, "auth_not_configured",
			"password login is not enabled on this server")
		return
	}
	var req struct {
		SchoolID string `json:"schoolId"`
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", "request body must be valid JSON")
		return
	}
	schoolID := req.SchoolID
	if s.SingleTenantSchoolID != "" {
		schoolID = s.SingleTenantSchoolID
	}

	id, err := auth.Authenticate(r.Context(), s.DB, domain.SchoolID(schoolID), req.Email, req.Password)
	switch {
	case errors.Is(err, auth.ErrInvalidCredential):
		writeError(w, http.StatusUnauthorized, "invalid_credentials", "Incorrect email or password")
		return
	case errors.Is(err, auth.ErrAccountDisabled):
		writeError(w, http.StatusForbidden, "account_disabled", "This account has been disabled")
		return
	case err != nil:
		writeInternal(w, r, "login_failed", err)
		return
	}

	token, err := s.Tokens.IssueAccess(id.UserID, accessTTL, time.Now())
	if err != nil {
		writeInternal(w, r, "login_failed", err)
		return
	}
	// Publish identity so the audit middleware logs the login against the user.
	if st := requestStateFrom(r.Context()); st != nil {
		st.identity = id
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"token":    token,
		"identity": toIdentityView(*id),
	})
}

// handleSignup — POST /auth/signup (public). Hand-rolled email/password
// self-signup (replaces /auth/firebase-signup). Creates the student account
// (onboarding-mode gated), issues an access token, and returns it + identity.
func (s *Server) handleSignup(w http.ResponseWriter, r *http.Request) {
	if s.Tokens == nil {
		writeError(w, http.StatusServiceUnavailable, "auth_not_configured",
			"password signup is not enabled on this server")
		return
	}
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
		writeError(w, http.StatusBadRequest, "bad_json", "request body must be valid JSON")
		return
	}
	schoolID := req.SchoolID
	if s.SingleTenantSchoolID != "" {
		schoolID = s.SingleTenantSchoolID
	}

	id, err := signup.Register(r.Context(), s.DB, signup.SignupRequest{
		SchoolID:               domain.SchoolID(schoolID),
		Name:                   req.Name,
		Email:                  req.Email,
		Phone:                  req.Phone,
		Password:               req.Password,
		TransmissionPreference: domain.Transmission(req.TransmissionPreference),
		LicenceCategoryPursued: domain.LicenceCategory(req.LicenceCategoryPursued),
		DateOfBirth:            req.DateOfBirth,
	})
	switch {
	case errors.Is(err, auth.ErrPasswordTooShort):
		writeError(w, http.StatusBadRequest, "password_too_short", "Password must be at least 8 characters")
		return
	case errors.Is(err, auth.ErrPasswordTooLong):
		writeError(w, http.StatusBadRequest, "password_too_long", "Password is too long")
		return
	case err != nil:
		writeSignupError(w, err)
		return
	}

	token, err := s.Tokens.IssueAccess(id.UserID, accessTTL, time.Now())
	if err != nil {
		writeInternal(w, r, "signup_failed", err)
		return
	}
	if st := requestStateFrom(r.Context()); st != nil {
		st.identity = id
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"token":    token,
		"identity": toIdentityView(*id),
	})
}

// handlePasswordResetRequest — POST /auth/password-reset/request (public).
// Emails a reset link if the address has an account. ALWAYS returns 204 (even
// for unknown emails) so it can't be used to discover who has an account.
func (s *Server) handlePasswordResetRequest(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SchoolID string `json:"schoolId"`
		Email    string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", "request body must be valid JSON")
		return
	}
	schoolID := req.SchoolID
	if s.SingleTenantSchoolID != "" {
		schoolID = s.SingleTenantSchoolID
	}
	email := strings.ToLower(strings.TrimSpace(req.Email))

	// Look up the user; on any miss we still return 204 (no enumeration).
	var userID, name string
	err := s.DB.QueryRowContext(r.Context(),
		`SELECT id, name FROM users WHERE school_id = ? AND email = ? AND account_status != 'disabled'`,
		schoolID, email).Scan(&userID, &name)
	if err == nil {
		if token, terr := auth.CreateResetToken(r.Context(), s.DB, domain.SchoolID(schoolID), domain.UserID(userID), time.Now()); terr == nil {
			s.sendResetEmail(email, name, token)
		} else {
			writeInternal(w, r, "reset_request_failed", terr)
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// sendResetEmail delivers the reset link best-effort (async so the response —
// and its timing — is the same whether or not the account exists).
func (s *Server) sendResetEmail(addr, name, token string) {
	if s.EmailSender == nil {
		return
	}
	link := token
	if s.ResetURLBase != "" {
		link = s.ResetURLBase + "?token=" + token
	}
	body := "Hi " + firstName(name) + ",\n\n" +
		"We received a request to reset your password. Use this link (valid for 1 hour):\n\n" +
		link + "\n\nIf you didn't request this, you can ignore this email."
	sender := s.EmailSender
	go func() {
		_ = sender.Send(context.Background(), email.Message{To: addr, ToName: name, Subject: "Reset your password", Body: body})
	}()
}

// handlePasswordResetConfirm — POST /auth/password-reset/confirm (public).
// Validates the reset token and sets the new password (single-use).
func (s *Server) handlePasswordResetConfirm(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token       string `json:"token"`
		NewPassword string `json:"newPassword"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", "request body must be valid JSON")
		return
	}
	hash, err := auth.HashPassword(req.NewPassword)
	switch {
	case errors.Is(err, auth.ErrPasswordTooShort):
		writeError(w, http.StatusBadRequest, "password_too_short", "Password must be at least 8 characters")
		return
	case errors.Is(err, auth.ErrPasswordTooLong):
		writeError(w, http.StatusBadRequest, "password_too_long", "Password is too long")
		return
	case err != nil:
		writeInternal(w, r, "reset_failed", err)
		return
	}

	userID, _, err := auth.ConsumeResetToken(r.Context(), s.DB, req.Token, time.Now())
	if errors.Is(err, auth.ErrSessionInvalid) {
		writeError(w, http.StatusBadRequest, "invalid_token", "This reset link is invalid or has expired")
		return
	}
	if err != nil {
		writeInternal(w, r, "reset_failed", err)
		return
	}
	if err := auth.SetPassword(r.Context(), s.DB, userID, hash); err != nil {
		writeInternal(w, r, "reset_failed", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
