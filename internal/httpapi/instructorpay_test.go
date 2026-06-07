package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestInstructorPay_AdminListOutstanding(t *testing.T) {
	f := newLedgerFixture(t)
	// Add an earning for the seeded instructor.
	resp, _ := f.do("POST", "/instructors/user_instr/earnings",
		map[string]any{"amountPence": 6000, "basis": "per_day", "notes": "CBT day 1"},
		f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("earn: %d", resp.StatusCode)
	}

	resp, body := f.do("GET", "/instructor-pay/outstanding", nil, f.adminToken)
	if resp.StatusCode != 200 {
		t.Fatalf("outstanding: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"totalOwedPence":6000`) {
		t.Errorf("expected totalOwedPence 6000, got %s", body)
	}
}

func TestInstructorPay_AdminRecordEarningAndPayment(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/instructors/user_instr/earnings",
		map[string]any{"amountPence": 10000, "basis": "per_day"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("earn: %d body=%s", resp.StatusCode, body)
	}
	resp, body = f.do("POST", "/instructors/user_instr/payments",
		map[string]any{"amountPence": 6000, "method": "bank_transfer", "paidAt": f.now.Format(time.RFC3339)},
		f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("pay: %d body=%s", resp.StatusCode, body)
	}
	resp, body = f.do("GET", "/instructor-pay/outstanding", nil, f.adminToken)
	if !strings.Contains(string(body), `"totalOwedPence":4000`) {
		t.Errorf("expected 4000 outstanding, got %s", body)
	}
}

func TestInstructorPay_StudentRejected(t *testing.T) {
	f := newLedgerFixture(t)
	resp, _ := f.do("GET", "/instructor-pay/outstanding", nil, f.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestInstructorPay_InstructorRejected(t *testing.T) {
	f := newLedgerFixture(t)
	instructor := f.loginAs("instr@test")
	resp, _ := f.do("POST", "/instructors/user_instr/earnings",
		map[string]any{"amountPence": 1000, "basis": "per_day"}, instructor)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 (instructor cannot record their own earnings), got %d", resp.StatusCode)
	}
}

func TestInstructorPay_SetPayModel(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("PUT", "/instructors/user_instr/pay-model",
		map[string]any{"payBasis": "percentage", "rateValue": 6000}, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("expected 204, got %d body=%s", resp.StatusCode, body)
	}
}

func TestInstructorPay_VoidEarning(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/instructors/user_instr/earnings",
		map[string]any{"amountPence": 5000, "basis": "per_day"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatal("earn")
	}
	var e struct{ ID string }
	json.Unmarshal(body, &e)

	resp, _ = f.do("DELETE", "/earnings/"+e.ID, nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("expected 204, got %d", resp.StatusCode)
	}
	resp, body = f.do("GET", "/instructor-pay/outstanding", nil, f.adminToken)
	if !strings.Contains(string(body), `"totalOwedPence":0`) {
		t.Errorf("expected 0 owed after void, got %s", body)
	}
}
