package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// signupFixture: API fixture + an admin user for the approval endpoints.
type signupFixture struct {
	*apiFixture
	adminToken string
}

func newSignupFixture(t *testing.T, onboardingMode string) *signupFixture {
	t.Helper()
	f := newAPIFixture(t)
	if _, err := f.db.Exec(`UPDATE schools SET onboarding_mode = ? WHERE id = 'school_t'`, onboardingMode); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                       VALUES ('user_admin','school_t','admin@test','','Admin','admin','active',?)`,
		f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	sf := &signupFixture{apiFixture: f}
	sf.adminToken = f.mintToken("user_admin")
	return sf
}

// ----- Tests -----

func TestListSchools_Public(t *testing.T) {
	f := newAPIFixture(t)
	resp, body := f.do("GET", "/schools", nil, "")
	if resp.StatusCode != 200 {
		t.Fatalf("expected 200 (public), got %d", resp.StatusCode)
	}
	if !strings.Contains(string(body), "Test School") {
		t.Errorf("expected school in response, got %s", body)
	}
}

func TestSignup_OpenMode_LandsActive(t *testing.T) {
	f := newSignupFixture(t, "open")
	resp, body, _ := f.signupViaFirebase(map[string]any{
		"schoolId":               "school_t",
		"name":                   "Newbie Norman",
		"email":                  "newbie@test.com",
		"phone":                  "+44 7700 900000",
		"transmissionPreference": "manual",
		"licenceCategoryPursued": "A2",
	})
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"accountStatus":"active"`) {
		t.Errorf("expected active account in open mode, got %s", body)
	}
}

func TestSignup_ApprovalMode_LandsPending(t *testing.T) {
	f := newSignupFixture(t, "approval")
	resp, body, _ := f.signupViaFirebase(map[string]any{
		"schoolId":               "school_t",
		"name":                   "Pending Pat",
		"email":                  "pat@test.com",
		"phone":                  "+44 7700 900111",
		"transmissionPreference": "manual",
		"licenceCategoryPursued": "A1",
	})
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"accountStatus":"pending_approval"`) {
		t.Errorf("expected pending_approval in approval mode, got %s", body)
	}
}

func TestSignup_InvalidSchool(t *testing.T) {
	f := newSignupFixture(t, "open")
	resp, b, _ := f.signupViaFirebase(map[string]any{
		"schoolId": "nope", "name": "X", "email": "x@y.com",
	})
	if resp.StatusCode != 404 || !strings.Contains(string(b), "school_not_found") {
		t.Errorf("expected 404 school_not_found, got %d body=%s", resp.StatusCode, b)
	}
}

func TestSignup_PendingUserCannotBookButCanBrowse(t *testing.T) {
	f := newSignupFixture(t, "approval")
	resp, body, tok := f.signupViaFirebase(map[string]any{
		"schoolId": "school_t", "name": "Pending", "email": "p@t.com",
		"transmissionPreference": "manual", "licenceCategoryPursued": "A1",
	})
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}

	// Browse: pending users can still see sessions.
	resp, _ = f.do("GET", "/sessions?from=2026-06-06T00:00:00Z&to=2026-07-01T00:00:00Z", nil, tok)
	if resp.StatusCode != 200 {
		t.Errorf("expected pending student CAN browse, got %d", resp.StatusCode)
	}
	// Book: should be 403.
	resp, _ = f.do("POST", "/bookings", map[string]string{"sessionId": "sess_t"}, tok)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for pending student book, got %d", resp.StatusCode)
	}
}

func TestSignups_AdminApprovalQueue(t *testing.T) {
	f := newSignupFixture(t, "approval")
	resp, body, _ := f.signupViaFirebase(map[string]any{
		"schoolId": "school_t", "name": "Pending Pat", "email": "pat@t.com",
		"transmissionPreference": "manual", "licenceCategoryPursued": "A1",
	})
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}
	var sig struct {
		Identity struct {
			UserID string `json:"userId"`
		}
	}
	json.Unmarshal(body, &sig)

	// Admin lists pending.
	resp, body = f.do("GET", "/signups/pending", nil, f.adminToken)
	if resp.StatusCode != 200 || !strings.Contains(string(body), "Pending Pat") {
		t.Errorf("pending list: %d body=%s", resp.StatusCode, body)
	}

	// Approve.
	resp, body = f.do("POST", "/signups/"+sig.Identity.UserID+"/approve", nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("approve: %d body=%s", resp.StatusCode, body)
	}

	// Second approve → 409 (no longer pending).
	resp, _ = f.do("POST", "/signups/"+sig.Identity.UserID+"/approve", nil, f.adminToken)
	if resp.StatusCode != 409 {
		t.Errorf("expected 409 second approve, got %d", resp.StatusCode)
	}
}

func TestSignups_StudentCannotReachApprovalEndpoints(t *testing.T) {
	f := newSignupFixture(t, "open")
	studentTok := f.loginStudent()
	resp, _ := f.do("GET", "/signups/pending", nil, studentTok)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for student, got %d", resp.StatusCode)
	}
}

func TestSignups_Reject(t *testing.T) {
	f := newSignupFixture(t, "approval")
	resp, body, tok := f.signupViaFirebase(map[string]any{
		"schoolId": "school_t", "name": "Reject Me", "email": "rej@t.com",
		"transmissionPreference": "manual", "licenceCategoryPursued": "A1",
	})
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}
	var sig struct {
		Identity struct {
			UserID string `json:"userId"`
		}
	}
	json.Unmarshal(body, &sig)

	resp, _ = f.do("POST", "/signups/"+sig.Identity.UserID+"/reject", nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("reject: %d", resp.StatusCode)
	}

	// Rejected user's token still verifies at Firebase (we don't revoke
	// refresh tokens — see "1-hour revocation window" note in the auth
	// architecture). But the middleware's LoadByFirebaseUID returns
	// ErrAccountDisabled because account_status flipped to 'disabled'.
	resp, body = f.do("GET", "/me", nil, tok)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 after reject, got %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "account_disabled") {
		t.Errorf("expected account_disabled code, got %s", body)
	}
}
