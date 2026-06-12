package httpapi_test

import (
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/httpapi"
)

// TestAuth_RoleAccessMatrix sweeps every route declared in
// server.RouteTable() against every role (student, instructor, admin,
// owner) and asserts the role gate decision matches the policy table
// below. The policy table is the canonical access spec — every new
// authenticated route needs a row added here or the sweep fails.
//
// What we assert:
//   - "allowed" cell  → status != 401 && status != 403. We don't care
//     whether the handler then returns 200, 400, 404 etc — only that
//     the role gate let the request through.
//   - "denied" cell   → status == 403.
//
// What we do NOT assert: response bodies, business outcomes,
// ownership checks beyond the role gate. The ownership matrix
// (instructor-can-only-read-own-receipt etc) is covered separately
// in receipts_test.go and ledger_test.go.

// roleSet is a 4-bit allow-list. Helpers below cover the common shapes.
type roleSet struct {
	student, instructor, admin, owner bool
}

func (r roleSet) allows(role string) bool {
	switch role {
	case "student":
		return r.student
	case "instructor":
		return r.instructor
	case "admin":
		return r.admin
	case "owner":
		return r.owner
	}
	return false
}

var (
	anyAuthed      = roleSet{true, true, true, true}
	staff          = roleSet{false, true, true, true}
	adminOwner     = roleSet{false, false, true, true}
	instructorOnly = roleSet{false, true, false, false}
	studentOnly    = roleSet{true, false, false, false}
)

// accessRow declares the allowed roles for a single (method, pattern)
// pair. pathSubs override path-param substitution for routes whose
// handlers do an ownership check we want to consistently exercise.
type accessRow struct {
	method   string
	pattern  string
	allowed  roleSet
	pathSubs map[string]string
}

// substitute replaces `{name}` in the pattern with the user's own ID
// (when the matrix says so) or a stable placeholder otherwise. Keeps
// the role gate path under test consistent.
func (r accessRow) substitute(role string, users map[string]string) string {
	path := r.pattern
	// Per-row overrides win.
	for k, v := range r.pathSubs {
		path = strings.ReplaceAll(path, "{"+k+"}", v)
	}
	// Standard substitutions for un-overridden params.
	path = strings.ReplaceAll(path, "{slotId}", "slot_t")
	path = strings.ReplaceAll(path, "{timeOffId}", "to_t")
	path = strings.ReplaceAll(path, "{chargeId}", "ch_t")
	path = strings.ReplaceAll(path, "{paymentId}", "py_t")
	path = strings.ReplaceAll(path, "{earningId}", "ea_t")
	path = strings.ReplaceAll(path, "{disruptionId}", "d_t")
	path = strings.ReplaceAll(path, "{bookingId}", "bk_t")
	path = strings.ReplaceAll(path, "{compId}", "comp_t")
	path = strings.ReplaceAll(path, "{noteId}", "n_t")
	path = strings.ReplaceAll(path, "{testId}", "t_t")
	path = strings.ReplaceAll(path, "{from}", "loc_t")
	path = strings.ReplaceAll(path, "{to}", "loc_t2")
	path = strings.ReplaceAll(path, "{token}", "tok_t")
	// /students/{id} — use the testing student's own ID so the
	// ownership check passes for them. Other roles always pass the
	// role gate regardless.
	if strings.Contains(path, "/students/{id}") {
		path = strings.ReplaceAll(path, "/students/{id}", "/students/"+users["student"])
	}
	// /instructors/{id} — use the testing instructor's own ID.
	if strings.Contains(path, "/instructors/{id}") {
		path = strings.ReplaceAll(path, "/instructors/{id}", "/instructors/"+users["instructor"])
	}
	// /sessions/{id} — any session.
	path = strings.ReplaceAll(path, "/sessions/{id}", "/sessions/sess_t")
	// /bookings/{id} — placeholder.
	path = strings.ReplaceAll(path, "/bookings/{id}", "/bookings/bk_t")
	// /bikes/{id} — placeholder.
	path = strings.ReplaceAll(path, "/bikes/{id}", "/bikes/bike_t")
	// /locations/{id} — placeholder.
	path = strings.ReplaceAll(path, "/locations/{id}", "/locations/loc_t")
	// /course-types/{id} — placeholder.
	path = strings.ReplaceAll(path, "/course-types/{id}", "/course-types/ct_cbt")
	// /signups/{id} — placeholder user id.
	path = strings.ReplaceAll(path, "/signups/{id}", "/signups/x")
	// /expenses/{id} — placeholder.
	path = strings.ReplaceAll(path, "/expenses/{id}", "/expenses/x")
	// /me/expenses/{id} — placeholder.
	path = strings.ReplaceAll(path, "/me/expenses/{id}", "/me/expenses/x")
	// /bike-expenses/{id} — placeholder (bike maintenance log).
	path = strings.ReplaceAll(path, "/bike-expenses/{id}", "/bike-expenses/x")
	// /me/notifications/{id} — placeholder.
	path = strings.ReplaceAll(path, "/me/notifications/{id}", "/me/notifications/x")
	// Final catch-all for unhandled {id}.
	path = regexp.MustCompile(`\{[^}]+\}`).ReplaceAllString(path, "x")
	_ = role
	return path
}

// authMatrix declares the role policy for every authenticated route
// the server mounts. Order roughly mirrors server.go's routeTable()
// for greppability.
var authMatrix = []accessRow{
	// Identity + browse — any signed-in user.
	{"GET", "/me", anyAuthed, nil},
	{"GET", "/sessions", anyAuthed, nil},
	{"GET", "/sessions/{id}/suitable-bikes", anyAuthed, nil},
	{"GET", "/sessions/{id}/detail", staff, nil},

	// Bookings — students may book/cancel/reschedule; staff may book
	// on behalf of students via the same endpoint.
	{"POST", "/bookings", anyAuthed, nil},
	{"DELETE", "/bookings/{id}", anyAuthed, nil},
	{"POST", "/bookings/{id}/reschedule", anyAuthed, nil},
	{"POST", "/bookings/{id}/assign-bike", adminOwner, nil},
	{"GET", "/me/bookings", studentOnly, nil},
	{"GET", "/me/student-profile", studentOnly, nil},
	{"GET", "/students/{id}/bookings", anyAuthed, nil},
	{"GET", "/students", staff, nil},
	{"POST", "/students", adminOwner, nil},
	{"GET", "/audit", adminOwner, nil},
	{"GET", "/compliance", adminOwner, nil},
	{"PUT", "/school/insurance", adminOwner, nil},
	{"GET", "/revenue", adminOwner, nil},
	{"GET", "/session-templates", adminOwner, nil},
	{"POST", "/session-templates", adminOwner, nil},
	{"DELETE", "/session-templates/{id}", adminOwner, nil},
	{"POST", "/session-templates/materialise", adminOwner, nil},
	{"GET", "/session-templates/{id}/preview", adminOwner, nil},
	{"POST", "/session-templates/{id}/materialise", adminOwner, nil},
	{"GET", "/session-templates/materialisations", adminOwner, nil},
	{"POST", "/session-templates/materialisations/{id}/undo", adminOwner, nil},
	{"POST", "/sessions/{id}/waitlist", studentOnly, nil},
	{"DELETE", "/sessions/{id}/waitlist", studentOnly, nil},
	{"GET", "/sessions/{id}/waitlist", staff, nil},
	{"GET", "/me/waitlist", studentOnly, nil},
	{"GET", "/closures", adminOwner, nil},
	{"POST", "/closures", adminOwner, nil},
	{"DELETE", "/closures/{id}", adminOwner, nil},
	{"POST", "/sessions", adminOwner, nil},
	{"PATCH", "/sessions/{id}", adminOwner, nil},
	{"PUT", "/sessions/{id}/instructors", adminOwner, nil},
	{"POST", "/sessions/cancel-batch", adminOwner, nil},
	{"GET", "/followups", staff, nil},
	{"GET", "/incidents/{id}/followups", staff, nil},
	{"POST", "/followups/{id}/done", staff, nil},
	{"POST", "/followups/{id}/reopen", staff, nil},

	// Ledger — admin/owner write, instructor can read.
	{"GET", "/students/{id}/ledger", anyAuthed, nil},
	{"POST", "/students/{id}/charges", adminOwner, nil},
	{"DELETE", "/charges/{chargeId}", adminOwner, nil},
	{"POST", "/students/{id}/payments", staff, nil}, // engine narrows further when instructors_can_record_payments=0
	{"DELETE", "/payments/{paymentId}", adminOwner, nil},

	// Signup approval queue — admin/owner.
	{"GET", "/signups/pending", adminOwner, nil},
	{"GET", "/signups/rejected", adminOwner, nil},
	{"POST", "/signups/{id}/approve", adminOwner, nil},
	{"POST", "/signups/{id}/reject", adminOwner, nil},
	{"POST", "/signups/{id}/restore", adminOwner, nil},

	// Locations + travel matrix — read any-staff, write admin/owner.
	{"GET", "/locations", anyAuthed, nil},
	{"POST", "/locations", adminOwner, nil},
	{"PUT", "/locations/{id}", adminOwner, nil},
	{"DELETE", "/locations/{id}", adminOwner, nil},
	{"GET", "/travel-times", anyAuthed, nil},
	{"PUT", "/travel-times", adminOwner, nil},
	{"DELETE", "/travel-times/{from}/{to}", adminOwner, nil},

	// Fleet — read any-staff, write admin/owner.
	{"GET", "/bikes", anyAuthed, nil},
	{"POST", "/bikes", adminOwner, nil},
	{"PUT", "/bikes/{id}", adminOwner, nil},
	{"POST", "/bikes/{id}/restore", staff, nil},
	{"POST", "/bikes/{id}/move", staff, nil},
	{"POST", "/bikes/{id}/mileage", staff, nil},
	{"POST", "/bikes/{id}/gps", adminOwner, nil},
	{"GET", "/admin/bikes/gps", adminOwner, nil},
	{"GET", "/admin/analytics/bike-utilisation", adminOwner, nil},
	{"GET", "/admin/analytics/instructor-utilisation", adminOwner, nil},
	{"GET", "/admin/analytics/funnel", adminOwner, nil},
	{"DELETE", "/bikes/{id}", adminOwner, nil},

	// Course catalog — read any-staff, write admin/owner.
	{"GET", "/course-types", anyAuthed, nil},
	{"POST", "/course-types", adminOwner, nil},
	{"PUT", "/course-types/{id}", adminOwner, nil},
	{"DELETE", "/course-types/{id}", adminOwner, nil},
	{"GET", "/course-types/{id}/competencies", anyAuthed, nil},
	{"POST", "/course-types/{id}/competencies", adminOwner, nil},
	{"DELETE", "/competencies/{compId}", adminOwner, nil},

	// Staff CRUD.
	{"GET", "/instructors", anyAuthed, nil},
	{"POST", "/instructors", adminOwner, nil},
	{"PUT", "/instructors/{id}/accreditations", adminOwner, nil},

	// Availability — instructor manages own, admin can view/manage anyone.
	{"GET", "/instructors/{id}/availability", staff, nil},
	{"POST", "/instructors/{id}/availability", staff, nil},
	{"DELETE", "/availability/{slotId}", staff, nil},
	{"GET", "/instructors/{id}/time-off", staff, nil},
	{"POST", "/instructors/{id}/time-off", staff, nil},
	{"DELETE", "/time-off/{timeOffId}", staff, nil},

	// Records (incidents/notes/external tests) — staff only.
	{"POST", "/incidents", staff, nil},
	{"GET", "/students/{id}/incidents", staff, nil},
	{"GET", "/students/{id}/notes", staff, nil},
	{"POST", "/students/{id}/notes", staff, nil},
	{"DELETE", "/notes/{noteId}", staff, nil},
	{"GET", "/students/{id}/tests", anyAuthed, nil},
	{"POST", "/students/{id}/tests", staff, nil},
	{"PATCH", "/tests/{testId}", staff, nil},

	// Student detail aggregate — staff.
	{"GET", "/students/{id}", staff, nil},

	// Progress capture — staff only (handler then narrows further).
	{"POST", "/bookings/{id}/attendance", staff, nil},
	{"PUT", "/bookings/{id}/competencies/{compId}", staff, nil},
	{"PUT", "/bookings/{id}/notes", staff, nil},
	{"GET", "/students/{id}/progress", anyAuthed, nil},

	// Notifications — any signed-in user.
	{"GET", "/me/notifications", anyAuthed, nil},
	{"POST", "/me/notifications/{id}/read", anyAuthed, nil},
	{"POST", "/me/notifications/read-all", anyAuthed, nil},
	{"GET", "/me/notification-prefs", anyAuthed, nil},
	{"PUT", "/me/notification-prefs", anyAuthed, nil},
	{"POST", "/me/device-tokens", anyAuthed, nil},
	{"DELETE", "/me/device-tokens/{token}", anyAuthed, nil},

	// Master calendar — staff only.
	{"GET", "/calendar", staff, nil},

	// Logistics — staff (instructors need to see tomorrow's moves too).
	{"GET", "/logistics", staff, nil},

	// School settings — read any-staff, write admin/owner.
	{"GET", "/school", anyAuthed, nil},
	{"PATCH", "/school", adminOwner, nil},

	// Disruptions — staff create, admin/owner resolve.
	{"POST", "/bikes/{id}/offline", staff, nil},
	{"GET", "/disruptions", staff, nil},
	{"POST", "/disruptions/{disruptionId}/bookings/{bookingId}/resolve", adminOwner, nil},
	{"POST", "/disruptions/dismiss-past", adminOwner, nil},

	// Instructor pay — admin/owner.
	{"GET", "/instructor-pay/outstanding", adminOwner, nil},
	{"GET", "/instructors/{id}/pay-model", adminOwner, nil},
	{"PUT", "/instructors/{id}/pay-model", adminOwner, nil},
	{"POST", "/instructors/{id}/earnings", adminOwner, nil},
	{"DELETE", "/earnings/{earningId}", adminOwner, nil},
	{"POST", "/instructors/{id}/payments", adminOwner, nil},

	// Reimbursements — see receipts_test.go for ownership checks.
	{"GET", "/expense-categories", anyAuthed, nil},
	{"PUT", "/expense-categories", adminOwner, nil},
	{"POST", "/me/expenses", instructorOnly, nil},
	{"GET", "/me/expenses", anyAuthed, nil},
	{"DELETE", "/me/expenses/{id}", instructorOnly, nil},
	{"GET", "/expenses", adminOwner, nil},
	{"GET", "/expenses/{id}", staff, nil},
	{"GET", "/expenses/{id}/receipt", staff, nil},
	{"POST", "/expenses/{id}/approve", adminOwner, nil},
	{"POST", "/expenses/{id}/reject", adminOwner, nil},
	{"POST", "/expenses/{id}/reimburse", adminOwner, nil},

	// Bike maintenance log — admin/owner only.
	{"GET", "/bikes/{id}/expenses", adminOwner, nil},
	{"POST", "/bikes/{id}/expenses", adminOwner, nil},
	{"GET", "/bike-expenses/{id}/receipt", adminOwner, nil},
	{"DELETE", "/bike-expenses/{id}", adminOwner, nil},
}

// matrixFixture extends the receipt fixture with owner + instructor
// tokens so we have a mintable token for every role.
type matrixFixture struct {
	*ledgerFixture
	tokens map[string]string // role → token
	ids    map[string]string // role → user_id (used in path substitution)
}

func newMatrixFixture(t *testing.T) *matrixFixture {
	t.Helper()
	f := newLedgerFixture(t)
	now := time.Now().UTC().Format(time.RFC3339)
	// Add an owner user. Admin + student + instructor are seeded by the
	// underlying fixture.
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                       VALUES ('user_owner','school_t','owner@test','','Owner','owner','active',?)`, now); err != nil {
		t.Fatal(err)
	}
	return &matrixFixture{
		ledgerFixture: f,
		tokens: map[string]string{
			"student":    f.studentToken,
			"instructor": f.loginAs("instr@test"),
			"admin":      f.adminToken,
			"owner":      f.mintToken("user_owner"),
		},
		ids: map[string]string{
			"student":    "user_stu",
			"instructor": "user_instr",
			"admin":      "user_admin",
			"owner":      "user_owner",
		},
	}
}

// matrixCompleteness checks that every authenticated route in
// RouteTable() has a row in authMatrix. Catches "added a route, forgot
// to declare its policy" — which is the failure mode this whole test
// is designed to catch.
func TestAuth_RoleAccessMatrix_Complete(t *testing.T) {
	f := newMatrixFixture(t)
	routes := httpapi.NewServer(f.db, nil, f.fb).RouteTable()
	declared := map[string]bool{}
	for _, row := range authMatrix {
		declared[row.method+" "+row.pattern] = true
	}
	for _, r := range routes {
		if r.Public {
			continue
		}
		key := r.Method + " " + r.Pattern
		if !declared[key] {
			t.Errorf("route %s has no row in authMatrix — add one (security policy must be declared)", key)
		}
	}
	// Reverse: catch stale matrix entries for routes that were renamed/deleted.
	mounted := map[string]bool{}
	for _, r := range routes {
		mounted[r.Method+" "+r.Pattern] = true
	}
	for _, row := range authMatrix {
		key := row.method + " " + row.pattern
		if !mounted[key] {
			t.Errorf("authMatrix row %s isn't mounted — stale entry, remove it", key)
		}
	}
}

func TestAuth_RoleAccessMatrix_Sweep(t *testing.T) {
	f := newMatrixFixture(t)
	for _, row := range authMatrix {
		for _, role := range []string{"student", "instructor", "admin", "owner"} {
			path := row.substitute(role, f.ids)
			resp, body := f.do(row.method, path, map[string]any{}, f.tokens[role])
			expectAllowed := row.allowed.allows(role)
			gotForbidden := resp.StatusCode == http.StatusForbidden
			gotUnauthed := resp.StatusCode == http.StatusUnauthorized
			switch {
			case expectAllowed && (gotForbidden || gotUnauthed):
				t.Errorf("%s %s as %s: expected role gate to PASS, got %d body=%s",
					row.method, row.pattern, role, resp.StatusCode, snippet(body))
			case !expectAllowed && !gotForbidden:
				t.Errorf("%s %s as %s: expected 403, got %d body=%s",
					row.method, row.pattern, role, resp.StatusCode, snippet(body))
			}
		}
	}
}

// snippet trims a body for tidy test failure messages.
func snippet(b []byte) string {
	s := string(b)
	if len(s) > 120 {
		return s[:120] + "…"
	}
	return s
}
