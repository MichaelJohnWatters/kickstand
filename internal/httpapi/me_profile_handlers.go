package httpapi

import (
	"database/sql"
	"net/http"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// GET /me/student-profile — the student's own profile fields so the
// Flutter "Licence & documents" screen can render. Returns 404 if the
// caller isn't a student (profiles are student-only).
//
// We deliberately don't expose this for staff — they read student detail
// via /students/{id} which aggregates more.
func (s *Server) handleMyStudentProfile(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role != domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "student profiles are read via /students/{id}")
		return
	}
	const q = `
		SELECT COALESCE(sp.provisional_licence_no, ''),
		       COALESCE(sp.licence_category_pursued, ''),
		       COALESCE(sp.rider_date_of_birth, ''),
		       COALESCE(sp.transmission_preference, ''),
		       COALESCE(sp.cbt_certificate_held, 0),
		       COALESCE(sp.cbt_variant, ''),
		       COALESCE(sp.cbt_expires_on, ''),
		       COALESCE(sp.cbt_region, ''),
		       COALESCE(sp.theory_passed, 0),
		       COALESCE(sp.theory_passed_on, ''),
		       sch.region, sch.test_body_label
		FROM users u
		LEFT JOIN student_profiles sp ON sp.user_id = u.id AND sp.school_id = u.school_id
		JOIN schools sch ON sch.id = u.school_id
		WHERE u.id = ? AND u.school_id = ?
	`
	var (
		provisional, licCat, dob, transmission        string
		cbtHeldInt, theoryInt                          int
		cbtVariant, cbtExpires, cbtRegion              string
		theoryOn                                       string
		schoolRegion, testBodyLabel                    string
	)
	err := s.DB.QueryRowContext(r.Context(), q, string(id.UserID), string(id.SchoolID)).Scan(
		&provisional, &licCat, &dob, &transmission,
		&cbtHeldInt, &cbtVariant, &cbtExpires, &cbtRegion,
		&theoryInt, &theoryOn,
		&schoolRegion, &testBodyLabel,
	)
	if err == sql.ErrNoRows {
		writeError(w, http.StatusNotFound, "not_found", "profile not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"provisionalLicenceNo":   provisional,
		"licenceCategoryPursued": licCat,
		"dateOfBirth":            dob,
		"transmissionPreference": transmission,
		"cbtHeld":                cbtHeldInt == 1,
		"cbtVariant":             cbtVariant,
		"cbtExpiresOn":           cbtExpires,
		"cbtRegion":              cbtRegion,
		"theoryPassed":           theoryInt == 1,
		"theoryPassedOn":         theoryOn,
		"schoolRegion":           schoolRegion,
		"testBodyLabel":          testBodyLabel, // 'DVA' / 'DVSA'
	})
}
