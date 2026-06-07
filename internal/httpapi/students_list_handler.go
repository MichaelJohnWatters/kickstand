package httpapi

import (
	"net/http"
	"strings"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// GET /students?q=<search>
//
// Lightweight roster for the admin Students list. Returns id, name, email,
// phone, accountStatus, derived balancePence (charges − payments, void-filtered),
// completedBookings, and whether any active safety_flag notes exist. Staff-only.
//
// Designed to be a single query so a 200-student tenant returns in one
// round-trip; pagination can come later if any school crosses 1000.
func (s *Server) handleListStudents(w http.ResponseWriter, r *http.Request) {
	id, _ := identityFromContext(r.Context())
	if id.Role == domain.RoleStudent {
		writeError(w, http.StatusForbidden, "forbidden", "staff only")
		return
	}
	scope := tenant.NewScope(s.DB, id.SchoolID)
	q := strings.TrimSpace(r.URL.Query().Get("q"))

	const query = `
		SELECT
		    u.id, u.name, u.email, COALESCE(u.phone, ''), u.account_status,
		    COALESCE(sp.licence_category_pursued, ''),
		    COALESCE(sp.transmission_preference, ''),
		    COALESCE(sp.cbt_certificate_held, 0),
		    COALESCE(sp.theory_passed, 0),
		    COALESCE((SELECT SUM(amount_pence) FROM charges c
		              WHERE c.school_id = u.school_id AND c.student_id = u.id AND c.voided_at IS NULL), 0)
		    -
		    COALESCE((SELECT SUM(amount_pence) FROM payments p
		              WHERE p.school_id = u.school_id AND p.student_id = u.id AND p.voided_at IS NULL), 0)
		      AS balance_pence,
		    COALESCE((SELECT COUNT(*) FROM bookings b
		              WHERE b.school_id = u.school_id AND b.student_id = u.id
		                AND b.status = 'completed'), 0) AS completed_bookings,
		    COALESCE((SELECT COUNT(*) FROM student_notes n
		              WHERE n.school_id = u.school_id AND n.student_id = u.id
		                AND n.kind = 'safety_flag' AND n.is_active = 1), 0)
		      AS safety_flag_count,
		    -- "Passed" = has at least one external test with outcome='pass'
		    -- for a final practical (NI single 'practical' or GB 'mod2'). MOD 1
		    -- alone isn't enough — that's the off-road slow-control test only.
		    EXISTS(SELECT 1 FROM external_tests t
		           WHERE t.school_id = u.school_id AND t.student_id = u.id
		             AND t.outcome = 'pass'
		             AND t.test_type IN ('practical', 'mod2')) AS has_passed
		FROM users u
		LEFT JOIN student_profiles sp
		    ON sp.user_id = u.id AND sp.school_id = u.school_id
		WHERE u.school_id = ? AND u.role = 'student'
		  AND (? = '' OR u.name LIKE ? OR u.email LIKE ?)
		ORDER BY u.name ASC
		LIMIT 500
	`
	like := "%" + q + "%"
	rows, err := scope.Conn().QueryContext(r.Context(), query,
		string(scope.SchoolID()), q, like, like,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	defer rows.Close()

	out := make([]map[string]any, 0, 64)
	for rows.Next() {
		var (
			uid, name, email, phone, status string
			licCat, trans                   string
			cbtHeld, theoryPassed           int
			balance, completed              int64
			flagCount                       int
			passed                          int
		)
		if err := rows.Scan(&uid, &name, &email, &phone, &status,
			&licCat, &trans, &cbtHeld, &theoryPassed,
			&balance, &completed, &flagCount, &passed); err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
			return
		}
		out = append(out, map[string]any{
			"id":                     uid,
			"name":                   name,
			"email":                  email,
			"phone":                  phone,
			"accountStatus":          status,
			"licenceCategoryPursued": licCat,
			"transmissionPreference": trans,
			"stage":                  computeStage(status, cbtHeld == 1, theoryPassed == 1, int(completed), passed == 1),
			"balancePence":           balance,
			"completedBookings":      completed,
			"safetyFlagCount":        flagCount,
			"hasSafetyFlag":          flagCount > 0,
			"passed":                 passed == 1,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"students": out})
}

// computeStage derives a human-readable training stage from the student's
// account status and profile. Matches the design's `rec.stage` chip in the
// admin Students list.
//
// "Passed" wins over every active-training stage — once a student has their
// licence, the school doesn't care about CBT / theory / lessons-in-progress
// for surfacing purposes. Their detail screen still shows the full history.
func computeStage(accountStatus string, cbtHeld, theoryPassed bool, completed int, passed bool) string {
	switch accountStatus {
	case "pending_approval":
		return "Awaiting approval"
	case "disabled":
		return "Disabled"
	}
	if passed {
		return "Passed"
	}
	if !cbtHeld {
		return "Pre-CBT"
	}
	if !theoryPassed {
		return "CBT held"
	}
	if completed == 0 {
		return "Theory passed"
	}
	return "In training"
}
