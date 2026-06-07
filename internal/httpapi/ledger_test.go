package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// ledgerFixture extends the API fixture with admin + student users so we can
// test role-gated endpoints. We reuse newAPIFixture for the base wiring and
// add an admin user on top.
type ledgerFixture struct {
	*apiFixture
	adminToken   string
	studentToken string
}

func newLedgerFixture(t *testing.T) *ledgerFixture {
	t.Helper()
	f := newAPIFixture(t)

	// Add an admin user
	hash, err := hashPasswordHelper(f.password)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                       VALUES ('user_admin','school_t','admin@test',?,'Admin','admin','active',?)`,
		hash, f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}

	lf := &ledgerFixture{apiFixture: f}
	lf.adminToken = lf.loginAs("admin@test")
	lf.studentToken = lf.loginStudent()
	return lf
}

func (lf *ledgerFixture) loginAs(email string) string {
	lf.t.Helper()
	resp, body := lf.do("POST", "/auth/login",
		map[string]string{"email": email, "password": lf.password}, "")
	if resp.StatusCode != 200 {
		lf.t.Fatalf("login %s: status=%d body=%s", email, resp.StatusCode, body)
	}
	var out struct{ Token string }
	if err := json.Unmarshal(body, &out); err != nil {
		lf.t.Fatal(err)
	}
	return out.Token
}

// ----- Tests -----

func TestLedger_StudentCannotCreateCharge(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 100, "description": "x"}, f.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d body=%s", resp.StatusCode, body)
	}
}

func TestLedger_AdminCreateChargeAndViewLedger(t *testing.T) {
	f := newLedgerFixture(t)

	resp, body := f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 13000, "description": "CBT 125 day"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("create charge: %d body=%s", resp.StatusCode, body)
	}

	resp, body = f.do("GET", "/students/user_stu/ledger", nil, f.adminToken)
	if resp.StatusCode != 200 {
		t.Fatalf("get ledger: %d body=%s", resp.StatusCode, body)
	}
	var out struct {
		Balance struct {
			BalancePence int64 `json:"balancePence"`
		} `json:"balance"`
		Entries []map[string]any `json:"entries"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	if out.Balance.BalancePence != 13000 {
		t.Errorf("balance: got %d want 13000", out.Balance.BalancePence)
	}
	if len(out.Entries) != 1 {
		t.Errorf("entries: got %d want 1", len(out.Entries))
	}
}

func TestLedger_StudentCanViewOwnLedger(t *testing.T) {
	f := newLedgerFixture(t)
	// Admin creates a charge first
	_, _ = f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 13000, "description": "CBT"}, f.adminToken)

	resp, body := f.do("GET", "/students/user_stu/ledger", nil, f.studentToken)
	if resp.StatusCode != 200 {
		t.Fatalf("student get own ledger: %d body=%s", resp.StatusCode, body)
	}
}

func TestLedger_StudentCannotViewOthersLedger(t *testing.T) {
	f := newLedgerFixture(t)
	// Make a second student
	hash, _ := hashPasswordHelper(f.password)
	if _, err := f.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                       VALUES ('user_stu2','school_t','stu2@test',?,'Stu2','student','active',?)`,
		hash, f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	resp, _ := f.do("GET", "/students/user_stu2/ledger", nil, f.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestLedger_RecordPayment_ReducesBalance(t *testing.T) {
	f := newLedgerFixture(t)
	if _, _ = f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 13000, "description": "CBT"}, f.adminToken); true {
	}
	resp, body := f.do("POST", "/students/user_stu/payments",
		map[string]any{"amountPence": 5000, "method": "cash"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("payment: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"newBalance":8000`) {
		t.Errorf("expected newBalance 8000 in response, got %s", body)
	}
}

func TestLedger_InstructorCanRecordPaymentWhenAllowed(t *testing.T) {
	f := newLedgerFixture(t)
	// School setting defaults to 1 (allow). Login as instructor.
	instructorToken := f.loginAs("instr@test")
	// First create a charge as admin
	_, _ = f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 5000, "description": "x"}, f.adminToken)
	// Instructor records a payment
	resp, body := f.do("POST", "/students/user_stu/payments",
		map[string]any{"amountPence": 5000, "method": "cash"}, instructorToken)
	if resp.StatusCode != 201 {
		t.Fatalf("instructor payment: %d body=%s", resp.StatusCode, body)
	}
}

func TestLedger_InstructorBlockedWhenSchoolDisables(t *testing.T) {
	f := newLedgerFixture(t)
	if _, err := f.db.Exec(`UPDATE schools SET instructors_can_record_payments = 0`); err != nil {
		t.Fatal(err)
	}
	instructorToken := f.loginAs("instr@test")
	resp, _ := f.do("POST", "/students/user_stu/payments",
		map[string]any{"amountPence": 5000, "method": "cash"}, instructorToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestLedger_InstructorCannotCreateCharge(t *testing.T) {
	f := newLedgerFixture(t)
	instructorToken := f.loginAs("instr@test")
	resp, _ := f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 5000, "description": "x"}, instructorToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestLedger_VoidCharge(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 13000, "description": "CBT"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatal("create")
	}
	var c struct{ ID string }
	json.Unmarshal(body, &c)

	resp, _ = f.do("DELETE", "/charges/"+c.ID,
		map[string]any{"reason": "double-charged"}, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("expected 204, got %d", resp.StatusCode)
	}
	// Balance should be 0 now.
	resp, body = f.do("GET", "/students/user_stu/ledger", nil, f.adminToken)
	if !strings.Contains(string(body), `"balancePence":0`) {
		t.Errorf("expected balance 0 after void, got %s", body)
	}
}

// hashPasswordHelper avoids importing the auth package in the test file's
// other helpers (server_test.go already uses it).
func hashPasswordHelper(plain string) (string, error) {
	return authHashPassword(plain)
}
