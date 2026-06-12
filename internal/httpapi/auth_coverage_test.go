package httpapi_test

import (
	"net/http"
	"regexp"
	"strings"
	"testing"

	"github.com/michaeljohnwatters/kickstand/internal/httpapi"
)

// Auth-coverage tests sweep the entire route table declared in
// server.go and assert that every non-public route rejects requests
// with no token, a malformed token, and a structurally-valid but
// forged JWT. Adding a new route automatically picks it up — no
// per-route test boilerplate.
//
// Failures here are real security regressions, not flaky tests:
//
//   - 401 missing — the route forgot to wire authMiddleware.
//   - 401 forged — the middleware accepted an unverified JWT, e.g.
//     a regression to the old looksLikeJWT-then-trust path.
//   - 200/2xx on an empty/garbage token — the handler is reading
//     identity from the body or a header instead of context.

var pathParamRE = regexp.MustCompile(`\{[^}]+\}`)

// fillPath substitutes path params with a harmless placeholder so the
// router matches. Auth runs before any path-param validation, so the
// dummy value never reaches the handler logic.
func fillPath(pattern string) string {
	return pathParamRE.ReplaceAllString(pattern, "x")
}

func TestAuth_AllProtectedRoutes_RejectMissingToken(t *testing.T) {
	f := newAPIFixture(t)
	s := httpapi.NewServer(f.db, nil, f.fb)
	for _, r := range s.RouteTable() {
		if r.Public {
			continue
		}
		path := fillPath(r.Pattern)
		resp, body := f.do(r.Method, path, nil, "")
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s %s: expected 401 without token, got %d body=%s",
				r.Method, r.Pattern, resp.StatusCode, body)
		}
	}
}

func TestAuth_AllProtectedRoutes_RejectMalformedToken(t *testing.T) {
	f := newAPIFixture(t)
	s := httpapi.NewServer(f.db, nil, f.fb)
	// Random opaque hex — what the legacy session token used to look
	// like. The middleware doesn't keep a session-token branch any
	// more, so this should always 401.
	const garbage = "deadbeef1234567890abcdef"
	for _, r := range s.RouteTable() {
		if r.Public {
			continue
		}
		path := fillPath(r.Pattern)
		resp, body := f.do(r.Method, path, nil, garbage)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s %s: expected 401 with garbage token, got %d body=%s",
				r.Method, r.Pattern, resp.StatusCode, body)
		}
	}
}

func TestAuth_AllProtectedRoutes_RejectForgedJWT(t *testing.T) {
	f := newAPIFixture(t)
	s := httpapi.NewServer(f.db, nil, f.fb)
	// Three-segment garbage that has JWT shape but no valid signature.
	// If signature verification regressed, this would slip through.
	const forged = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJhdHRhY2tlciJ9.bad"
	for _, r := range s.RouteTable() {
		if r.Public {
			continue
		}
		path := fillPath(r.Pattern)
		resp, body := f.do(r.Method, path, nil, forged)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s %s: expected 401 with forged JWT, got %d body=%s",
				r.Method, r.Pattern, resp.StatusCode, body)
		}
	}
}

// TestAuth_PublicRoutes_DoNotRequireToken sanity-checks the opposite
// direction: public routes (listed in routeTable with Public=true)
// must NOT 401 when no token is sent. Catches accidental wrapping of
// a public route with authMiddleware.
//
// `/auth/firebase-signup` is exempt — it's mounted outside the middleware
// (the regular middleware would fail with ErrProfileMissing on the first
// call, since the profile row doesn't exist yet), but the handler still
// requires a Firebase JWT and verifies it inline.
func TestAuth_PublicRoutes_DoNotRequireToken(t *testing.T) {
	f := newAPIFixture(t)
	s := httpapi.NewServer(f.db, nil, f.fb)
	for _, r := range s.RouteTable() {
		if !r.Public {
			continue
		}
		if r.Pattern == "/auth/firebase-signup" {
			continue
		}
		path := fillPath(r.Pattern)
		resp, body := f.do(r.Method, path, nil, "")
		if resp.StatusCode == http.StatusUnauthorized {
			t.Errorf("%s %s: public route returned 401 — auth middleware leaked? body=%s",
				r.Method, r.Pattern, body)
		}
	}
}

// adminOnlyRoutes — endpoints any non-admin role MUST be refused at
// 403. Curated rather than enumerated because the role policy isn't
// declarative; the handler does the check inline. New admin-only
// routes need a row added here.
var adminOnlyRoutes = []struct{ method, pattern string }{
	// Admin CRUD
	{"POST", "/locations"},
	{"PUT", "/locations/x"},
	{"DELETE", "/locations/x"},
	{"PUT", "/travel-times"},
	{"DELETE", "/travel-times/x/y"},
	{"POST", "/bikes"},
	{"PUT", "/bikes/x"},
	{"DELETE", "/bikes/x"},
	{"POST", "/course-types"},
	{"PUT", "/course-types/x"},
	{"DELETE", "/course-types/x"},
	{"POST", "/course-types/x/competencies"},
	{"DELETE", "/competencies/x"},
	{"POST", "/instructors"},
	{"PUT", "/instructors/x/accreditations"},
	{"POST", "/students"},
	{"POST", "/students/x/charges"},
	{"DELETE", "/charges/x"},
	{"GET", "/signups/pending"},
	{"GET", "/signups/rejected"},
	{"GET", "/signups/approved"},
	{"GET", "/audit"},
	{"GET", "/compliance"},
	{"PUT", "/school/insurance"},
	{"GET", "/revenue"},
	{"GET", "/session-templates"},
	{"POST", "/session-templates"},
	{"DELETE", "/session-templates/x"},
	{"POST", "/session-templates/materialise"},
	{"GET", "/session-templates/x/preview"},
	{"POST", "/session-templates/x/materialise"},
	{"GET", "/session-templates/materialisations"},
	{"POST", "/session-templates/materialisations/x/undo"},
	{"GET", "/closures"},
	{"POST", "/closures"},
	{"DELETE", "/closures/x"},
	{"POST", "/sessions"},
	{"PATCH", "/sessions/x"},
	{"PUT", "/sessions/x/instructors"},
	{"POST", "/sessions/cancel-batch"},
	{"POST", "/signups/x/approve"},
	{"POST", "/signups/x/reject"},
	{"POST", "/signups/x/restore"},
	{"GET", "/logistics"},
	{"GET", "/instructor-pay/outstanding"},
	{"POST", "/instructors/x/earnings"},
	{"PUT", "/instructors/x/pay-model"},
	{"DELETE", "/earnings/x"},
	{"PUT", "/expense-categories"},
	{"POST", "/expenses/x/approve"},
	{"POST", "/expenses/x/reject"},
	{"POST", "/expenses/x/reimburse"},
	{"PATCH", "/school"},
}

func TestAuth_AdminOnlyRoutes_RejectStudent(t *testing.T) {
	f := newAPIFixture(t)
	studentTok := f.loginStudent()
	for _, r := range adminOnlyRoutes {
		resp, body := f.do(r.method, r.pattern, map[string]any{}, studentTok)
		if resp.StatusCode != http.StatusForbidden {
			t.Errorf("%s %s as student: expected 403, got %d body=%s",
				r.method, r.pattern, resp.StatusCode, body)
		}
		if !strings.Contains(string(body), "forbidden") &&
			!strings.Contains(string(body), "account_disabled") &&
			!strings.Contains(string(body), "not_my_expense") {
			t.Errorf("%s %s: 403 didn't carry a known forbidden code: %s",
				r.method, r.pattern, body)
		}
	}
}
