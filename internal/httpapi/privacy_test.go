package httpapi_test

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// GET /me/data-export — the caller pulls their own personal data.
// Asserts the basic shape, presence of the expected top-level keys,
// and the Content-Disposition header so the browser saves it.
func TestPrivacy_StudentExportsOwnData(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("GET", "/me/data-export", nil, f.studentToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("export: %d body=%s", resp.StatusCode, body)
	}
	if cd := resp.Header.Get("Content-Disposition"); !strings.Contains(cd, "kickstand-data-export.json") {
		t.Errorf("missing Content-Disposition for download: %q", cd)
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("decode: %v body=%s", err, body)
	}
	for _, key := range []string{
		"exportedAt", "user", "studentProfile", "bookings", "charges",
		"payments", "notes", "incidents", "externalTests", "waitlist",
		"notificationPrefs",
	} {
		if _, ok := out[key]; !ok {
			t.Errorf("export missing %q; body=%s", key, body)
		}
	}
	user := out["user"].(map[string]any)
	if user["email"] != "stu@test" {
		t.Errorf("expected email stu@test, got %v", user["email"])
	}
	if user["role"] != "student" {
		t.Errorf("expected role student, got %v", user["role"])
	}
}

// POST /admin/users/{id}/anonymise scrubs the row + flips the flag.
// A second call returns 409.
func TestPrivacy_AdminAnonymisesStudent(t *testing.T) {
	f := newLedgerFixture(t)
	// First call — succeeds.
	resp, body := f.do("POST", "/admin/users/user_stu/anonymise", nil, f.adminToken)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("anonymise: %d body=%s", resp.StatusCode, body)
	}
	// Confirm via SQL that PII is scrubbed and the timestamp landed.
	var name, email, anonAt string
	if err := f.db.QueryRow(
		`SELECT name, email, COALESCE(anonymised_at, '') FROM users WHERE id = 'user_stu'`,
	).Scan(&name, &email, &anonAt); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if name != "(Anonymised)" {
		t.Errorf("name not scrubbed: %q", name)
	}
	if !strings.HasPrefix(email, "anon-user_stu@") {
		t.Errorf("email not placeholdered: %q", email)
	}
	if anonAt == "" {
		t.Error("anonymised_at not set")
	}
	// Second call — idempotent guard returns 409.
	resp, body = f.do("POST", "/admin/users/user_stu/anonymise", nil, f.adminToken)
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("second call: expected 409, got %d body=%s", resp.StatusCode, body)
	}
}

// Admin can't anonymise themselves through this endpoint — would
// lock the school out of its own account mid-request.
func TestPrivacy_AdminCannotAnonymiseSelf(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/admin/users/user_admin/anonymise", nil, f.adminToken)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 self_target, got %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "self_target") {
		t.Errorf("expected error code self_target, got body=%s", body)
	}
}

// After erasure the user can still be looked up in admin listings —
// just with the placeholder name — so the FK chain (bookings,
// charges) stays renderable.
func TestPrivacy_BookingsSurviveErasure(t *testing.T) {
	f := newLedgerFixture(t)
	// Seed a charge against the student before we wipe them so we can
	// confirm the ledger row is untouched.
	resp, _ := f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 5000, "description": "Test charge"},
		f.adminToken)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create charge for fixture: %d", resp.StatusCode)
	}
	resp, _ = f.do("POST", "/admin/users/user_stu/anonymise", nil, f.adminToken)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("anonymise: %d", resp.StatusCode)
	}
	// The charge row should still be there with the same amount.
	var cnt, amt int
	if err := f.db.QueryRow(
		`SELECT COUNT(*), COALESCE(SUM(amount_pence), 0)
		 FROM charges WHERE student_id = 'user_stu' AND voided_at IS NULL`,
	).Scan(&cnt, &amt); err != nil {
		t.Fatalf("scan charges: %v", err)
	}
	if cnt != 1 || amt != 5000 {
		t.Errorf("expected 1 charge of 5000 pence, got %d charges totalling %d", cnt, amt)
	}
}
