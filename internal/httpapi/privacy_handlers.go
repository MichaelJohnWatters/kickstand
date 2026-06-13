package httpapi

import (
	"context"
	"errors"
	"net/http"

	firebaseauth "firebase.google.com/go/v4/auth"

	"github.com/michaeljohnwatters/kickstand/internal/audit"
	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/privacy"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// GET /me/data-export — caller's own personal data, GDPR Article 20
// (right of access / data portability). Any authenticated role.
// Returns the JSON payload with a Content-Disposition hint so the
// browser downloads it as a file.
func (s *Server) handleMyDataExport(w http.ResponseWriter, r *http.Request) {
	id, ok := identityFromContext(r.Context())
	if !ok || id == nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated", "no identity")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	out, err := privacy.Export(r.Context(), scope, id.UserID)
	if err != nil {
		if errors.Is(err, privacy.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "user not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	w.Header().Set("Content-Disposition", `attachment; filename="kickstand-data-export.json"`)
	audit.Describe(r.Context(), "Downloaded their own data export")
	writeJSON(w, http.StatusOK, out)
}

// POST /admin/users/{id}/anonymise — admin/owner only. Scrubs PII on
// the target user's row + role profile, then disables the Firebase
// Auth user so the (placeholder) email can never sign in again.
//
// Bookings, charges, payments, audit_log — all untouched. The user_id
// stays valid for FK reference; the user just becomes "(Anonymised)"
// everywhere it joins on users.name.
func (s *Server) handleAnonymiseUser(w http.ResponseWriter, r *http.Request) {
	caller, _ := identityFromContext(r.Context())
	if !requireAdminOwner(w, caller) {
		return
	}
	target := domain.UserID(r.PathValue("id"))
	if target == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "missing user id")
		return
	}
	if target == caller.UserID {
		// Self-anonymise locks the caller out mid-request — refuse so an
		// admin can't accidentally lock themselves out of the school.
		writeError(w, http.StatusBadRequest, "self_target",
			"can't anonymise your own account from this endpoint")
		return
	}
	scope := tenant.NewScope(s.DB, caller.SchoolID)
	if err := privacy.Anonymise(r.Context(), scope, target); err != nil {
		switch {
		case errors.Is(err, privacy.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found", "user not found")
		case errors.Is(err, privacy.ErrAlreadyAnonymised):
			writeError(w, http.StatusConflict, "already_anonymised",
				"this user has already been anonymised")
		default:
			writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		}
		return
	}
	// Disable the Firebase Auth user — best-effort. If this fails the
	// SQL scrub already landed, so we still surface 204 to the caller
	// and the audit row records the action. A retry of the endpoint
	// will return 409 already_anonymised; the auth disable can be
	// rerun via the standard Firebase admin tools.
	if s.Firebase != nil {
		_ = disableFirebaseUser(r.Context(), s.Firebase, target)
	}
	audit.Describe(r.Context(), "Anonymised user %s under right-to-erasure", string(target))
	w.WriteHeader(http.StatusNoContent)
}

// disableFirebaseUser flips the disabled flag on a Firebase Auth
// record so the (now placeholder) email can't sign in. Looks up the
// user by their Kickstand user id which is also their Firebase uid
// (Phase 5 of the auth migration unified them).
func disableFirebaseUser(ctx context.Context, fb *auth.FirebaseClient, id domain.UserID) error {
	update := (&firebaseauth.UserToUpdate{}).Disabled(true)
	_, err := fb.Auth.UpdateUser(ctx, string(id), update)
	return err
}
