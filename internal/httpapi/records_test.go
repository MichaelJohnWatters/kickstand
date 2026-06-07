package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"
)

// ----- Incidents -----

func TestRecordsHTTP_LogIncident_TakeBikeOffline(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/incidents", map[string]any{
		"bikeId":          "bike_t",
		"studentId":       "user_stu",
		"description":     "Brake pad shattered on lap 3",
		"takeBikeOffline": true,
		"offlineReason":   "broken",
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("log: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"tookBikeOffline":true`) {
		t.Errorf("expected tookBikeOffline=true, got %s", body)
	}

	// Bike status
	resp, body = f.do("GET", "/bikes", nil, f.adminToken)
	if !strings.Contains(string(body), `"status":"offline"`) {
		t.Errorf("expected bike offline, got %s", body)
	}
}

func TestRecordsHTTP_StudentCannotLogIncident(t *testing.T) {
	f := newLedgerFixture(t)
	resp, _ := f.do("POST", "/incidents",
		map[string]any{"description": "sneaky"}, f.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestRecordsHTTP_ListStudentIncidents(t *testing.T) {
	f := newLedgerFixture(t)
	if resp, _ := f.do("POST", "/incidents", map[string]any{
		"bikeId": "bike_t", "studentId": "user_stu",
		"description": "low-speed drop",
	}, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("seed")
	}
	resp, body := f.do("GET", "/students/user_stu/incidents", nil, f.adminToken)
	if resp.StatusCode != 200 || !strings.Contains(string(body), "low-speed drop") {
		t.Errorf("list: %d body=%s", resp.StatusCode, body)
	}
}

// ----- Notes -----

func TestRecordsHTTP_AddAndListNotes(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/students/user_stu/notes",
		map[string]string{"kind": "safety_flag", "body": "Low seat needed"},
		f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("add: %d body=%s", resp.StatusCode, body)
	}
	resp, body = f.do("GET", "/students/user_stu/notes?kind=safety_flag", nil, f.adminToken)
	if !strings.Contains(string(body), "Low seat needed") {
		t.Errorf("expected note in list, got %s", body)
	}
}

func TestRecordsHTTP_NotesStaffOnly(t *testing.T) {
	f := newLedgerFixture(t)
	// Student cannot list their own notes (staff-only at the API layer
	// — they're never meant to see the notes about them).
	resp, _ := f.do("GET", "/students/user_stu/notes", nil, f.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
	// Student cannot add a note about themselves either.
	resp, _ = f.do("POST", "/students/user_stu/notes",
		map[string]string{"kind": "safety_flag", "body": "self-praise"}, f.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for student add, got %d", resp.StatusCode)
	}
}

func TestRecordsHTTP_NoteInvalidKind(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/students/user_stu/notes",
		map[string]string{"kind": "rumour", "body": "x"}, f.adminToken)
	if resp.StatusCode != 400 || !strings.Contains(string(body), "invalid_kind") {
		t.Errorf("expected 400 invalid_kind, got %d body=%s", resp.StatusCode, body)
	}
}

func TestRecordsHTTP_DeactivateNote(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/students/user_stu/notes",
		map[string]string{"kind": "safety_flag", "body": "Old flag"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatal("seed")
	}
	var n struct{ ID string }
	json.Unmarshal(body, &n)
	resp, _ = f.do("DELETE", "/notes/"+n.ID, nil, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("deactivate: %d", resp.StatusCode)
	}
}

// ----- External tests -----

func TestRecordsHTTP_RecordExternalTest_NI(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/students/user_stu/tests", map[string]any{
		"testType": "practical", "region": "NI",
		"outcome": "booked",
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("record: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"attemptNumber":1`) {
		t.Errorf("expected attempt 1, got %s", body)
	}
}

func TestRecordsHTTP_RecordExternalTest_RejectsMod1ForNI(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/students/user_stu/tests", map[string]any{
		"testType": "mod1", "region": "NI", "outcome": "booked",
	}, f.adminToken)
	if resp.StatusCode != 400 || !strings.Contains(string(body), "invalid_input") {
		t.Errorf("expected 400 invalid_input, got %d body=%s", resp.StatusCode, body)
	}
}

func TestRecordsHTTP_UpdateOutcome(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/students/user_stu/tests", map[string]any{
		"testType": "practical", "region": "NI", "outcome": "booked",
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatal("seed")
	}
	var c struct{ ID string }
	json.Unmarshal(body, &c)

	resp, _ = f.do("PATCH", "/tests/"+c.ID,
		map[string]string{"outcome": "pass", "notes": "first try"}, f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("update: %d", resp.StatusCode)
	}
	resp, body = f.do("GET", "/students/user_stu/tests", nil, f.adminToken)
	if !strings.Contains(string(body), `"outcome":"pass"`) {
		t.Errorf("expected pass, got %s", body)
	}
}

func TestRecordsHTTP_Tests_StudentCanViewOwn(t *testing.T) {
	f := newLedgerFixture(t)
	if resp, _ := f.do("POST", "/students/user_stu/tests", map[string]any{
		"testType": "practical", "region": "NI", "outcome": "booked",
	}, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("seed")
	}
	resp, body := f.do("GET", "/students/user_stu/tests", nil, f.studentToken)
	if resp.StatusCode != 200 || !strings.Contains(string(body), `"testType":"practical"`) {
		t.Errorf("expected student to view own tests, got %d body=%s", resp.StatusCode, body)
	}
}

// ----- Student detail aggregate -----

func TestStudentDetail_AggregatesEverything(t *testing.T) {
	f := newLedgerFixture(t)

	// Charge + payment
	if resp, _ := f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 13000, "description": "CBT"}, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("charge")
	}
	if resp, _ := f.do("POST", "/students/user_stu/payments",
		map[string]any{"amountPence": 5000, "method": "cash"}, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("pay")
	}
	// Safety flag + note
	if resp, _ := f.do("POST", "/students/user_stu/notes",
		map[string]string{"kind": "safety_flag", "body": "Low seat needed"}, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("flag")
	}
	if resp, _ := f.do("POST", "/students/user_stu/notes",
		map[string]string{"kind": "progress_note", "body": "Doing well"}, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("note")
	}
	// External test
	if resp, _ := f.do("POST", "/students/user_stu/tests", map[string]any{
		"testType": "practical", "region": "NI", "outcome": "booked",
	}, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("test")
	}
	// Incident
	if resp, _ := f.do("POST", "/incidents", map[string]any{
		"bikeId": "bike_t", "studentId": "user_stu", "description": "low-speed drop",
	}, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("incident")
	}

	resp, body := f.do("GET", "/students/user_stu", nil, f.adminToken)
	if resp.StatusCode != 200 {
		t.Fatalf("detail: %d body=%s", resp.StatusCode, body)
	}
	must := []string{
		"\"balancePence\":8000",
		"Low seat needed",
		"Doing well",
		"\"testType\":\"practical\"",
		"low-speed drop",
	}
	for _, s := range must {
		if !strings.Contains(string(body), s) {
			t.Errorf("expected %q in detail response, missing from %s", s, body)
		}
	}
}

func TestStudentDetail_StudentRejected(t *testing.T) {
	f := newLedgerFixture(t)
	resp, _ := f.do("GET", "/students/user_stu", nil, f.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}
