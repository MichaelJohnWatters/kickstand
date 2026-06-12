package httpapi

import (
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
)

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
