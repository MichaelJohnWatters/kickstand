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
	hash, _ := authHashPassword(f.password)
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                       VALUES ('user_admin','school_t','admin@test',?,'Admin','admin','active',?)`,
		hash, f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	sf := &signupFixture{apiFixture: f}
	resp, body := f.do("POST", "/auth/login",
		map[string]string{"email": "admin@test", "password": f.password}, "")
	if resp.StatusCode != 200 {
		t.Fatalf("admin login: %d body=%s", resp.StatusCode, body)
	}
	var out struct{ Token string }
	json.Unmarshal(body, &out)
	sf.adminToken = out.Token
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
	resp, body := f.do("POST", "/auth/signup", map[string]any{
		"schoolId":               "school_t",
		"name":                   "Newbie Norman",
		"email":                  "newbie@test.com",
		"phone":                  "+44 7700 900000",
		"password":               "longenoughpw",
		"transmissionPreference": "manual",
		"licenceCategoryPursued": "A2",
	}, "")
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"accountStatus":"active"`) {
		t.Errorf("expected active account in open mode, got %s", body)
	}
}

func TestSignup_ApprovalMode_LandsPending(t *testing.T) {
	f := newSignupFixture(t, "approval")
	resp, body := f.do("POST", "/auth/signup", map[string]any{
		"schoolId":               "school_t",
		"name":                   "Pending Pat",
		"email":                  "pat@test.com",
		"phone":                  "+44 7700 900111",
		"password":               "longenoughpw",
		"transmissionPreference": "manual",
		"licenceCategoryPursued": "A1",
	}, "")
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"accountStatus":"pending_approval"`) {
		t.Errorf("expected pending_approval in approval mode, got %s", body)
	}
}

func TestSignup_DuplicateEmailRejected(t *testing.T) {
	f := newSignupFixture(t, "open")
	body := map[string]any{
		"schoolId":               "school_t",
		"name":                   "Dup",
		"email":                  "dup@test.com",
		"password":               "longenoughpw",
		"transmissionPreference": "manual",
		"licenceCategoryPursued": "A1",
	}
	resp, _ := f.do("POST", "/auth/signup", body, "")
	if resp.StatusCode != 201 {
		t.Fatalf("first: %d", resp.StatusCode)
	}
	resp, b := f.do("POST", "/auth/signup", body, "")
	if resp.StatusCode != 409 {
		t.Errorf("expected 409 duplicate, got %d body=%s", resp.StatusCode, b)
	}
	if !strings.Contains(string(b), "email_in_use") {
		t.Errorf("expected email_in_use code, got %s", b)
	}
}

func TestSignup_ShortPassword(t *testing.T) {
	f := newSignupFixture(t, "open")
	resp, b := f.do("POST", "/auth/signup", map[string]any{
		"schoolId": "school_t", "name": "X", "email": "x@y.com",
		"password": "short",
	}, "")
	if resp.StatusCode != 400 || !strings.Contains(string(b), "password_too_short") {
		t.Errorf("expected 400 password_too_short, got %d body=%s", resp.StatusCode, b)
	}
}

func TestSignup_InvalidSchool(t *testing.T) {
	f := newSignupFixture(t, "open")
	resp, b := f.do("POST", "/auth/signup", map[string]any{
		"schoolId": "nope", "name": "X", "email": "x@y.com",
		"password": "longenoughpw",
	}, "")
	if resp.StatusCode != 404 || !strings.Contains(string(b), "school_not_found") {
		t.Errorf("expected 404 school_not_found, got %d body=%s", resp.StatusCode, b)
	}
}

func TestSignup_PendingUserCannotBookButCanBrowse(t *testing.T) {
	// End-to-end: signup in approval mode, get token, try to book → 403.
	f := newSignupFixture(t, "approval")
	resp, body := f.do("POST", "/auth/signup", map[string]any{
		"schoolId": "school_t", "name": "Pending", "email": "p@t.com",
		"password": "longenoughpw", "transmissionPreference": "manual",
		"licenceCategoryPursued": "A1",
	}, "")
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}
	var out struct{ Token string }
	json.Unmarshal(body, &out)

	// Browse: should succeed (returns sessions)
	resp, _ = f.do("GET", "/sessions?from=2026-06-06T00:00:00Z&to=2026-07-01T00:00:00Z", nil, out.Token)
	if resp.StatusCode != 200 {
		t.Errorf("expected pending student CAN browse, got %d", resp.StatusCode)
	}
	// Book: should be 403
	resp, _ = f.do("POST", "/bookings", map[string]string{"sessionId": "sess_t"}, out.Token)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for pending student book, got %d", resp.StatusCode)
	}
}

func TestSignups_AdminApprovalQueue(t *testing.T) {
	f := newSignupFixture(t, "approval")
	// Sign a student up
	resp, body := f.do("POST", "/auth/signup", map[string]any{
		"schoolId": "school_t", "name": "Pending Pat", "email": "pat@t.com",
		"password": "longenoughpw", "transmissionPreference": "manual",
		"licenceCategoryPursued": "A1",
	}, "")
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}
	var sig struct{ Identity struct{ UserID string `json:"userId"` } }
	json.Unmarshal(body, &sig)

	// Admin lists pending
	resp, body = f.do("GET", "/signups/pending", nil, f.adminToken)
	if resp.StatusCode != 200 || !strings.Contains(string(body), "Pending Pat") {
		t.Errorf("pending list: %d body=%s", resp.StatusCode, body)
	}

	// Approve
	resp, body = f.do("POST", "/signups/"+sig.Identity.UserID+"/approve", nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("approve: %d body=%s", resp.StatusCode, body)
	}

	// Second approve → 409 (already pending=false)
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
	resp, body := f.do("POST", "/auth/signup", map[string]any{
		"schoolId": "school_t", "name": "Reject Me", "email": "rej@t.com",
		"password": "longenoughpw", "transmissionPreference": "manual",
		"licenceCategoryPursued": "A1",
	}, "")
	var sig struct{ Identity struct{ UserID string `json:"userId"` } }
	json.Unmarshal(body, &sig)

	resp, _ = f.do("POST", "/signups/"+sig.Identity.UserID+"/reject", nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("reject: %d", resp.StatusCode)
	}

	// User can't log in any more
	resp, b := f.do("POST", "/auth/login", map[string]string{"email": "rej@t.com", "password": "longenoughpw"}, "")
	if resp.StatusCode != 403 || !strings.Contains(string(b), "account_disabled") {
		t.Errorf("expected 403 account_disabled after reject, got %d body=%s", resp.StatusCode, b)
	}
}
