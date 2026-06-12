package httpapi_test

import (
	"strings"
	"testing"
	"time"
)

func TestAvailability_InstructorManagesOwn(t *testing.T) {
	f := newLedgerFixture(t)
	tok := f.loginAs("instr@test")
	resp, body := f.do("POST", "/instructors/user_instr/availability",
		map[string]any{
			"weekday":       1, // Monday
			"startsAtLocal": "09:00",
			"endsAtLocal":   "13:00",
			"locationId":    "loc_t",
		}, tok)
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d body=%s", resp.StatusCode, body)
	}
}

func TestAvailability_InstructorCannotManageOther(t *testing.T) {
	f := newLedgerFixture(t)
	// Add a second instructor.
	if resp, _ := f.do("POST", "/instructors", map[string]any{
		"name": "Other", "email": "other@test.com", "password": "longenoughpw",
		"homeLocationId": "loc_t", "accreditations": []map[string]any{
			{"courseTypeId": "ct_cbt"},
		},
	}, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("invite")
	}
	otherTok := f.loginAs("other@test.com")
	resp, _ := f.do("POST", "/instructors/user_instr/availability",
		map[string]any{
			"weekday": 1, "startsAtLocal": "09:00", "endsAtLocal": "13:00",
		}, otherTok)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestAvailability_InvalidTimes(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/instructors/user_instr/availability",
		map[string]any{"weekday": 1, "startsAtLocal": "13:00", "endsAtLocal": "09:00"},
		f.adminToken)
	if resp.StatusCode != 400 || !strings.Contains(string(body), "invalid_input") {
		t.Errorf("expected 400 invalid_input, got %d body=%s", resp.StatusCode, body)
	}
}

func TestAvailability_AddAndListTimeOff(t *testing.T) {
	f := newLedgerFixture(t)
	resp, body := f.do("POST", "/instructors/user_instr/time-off", map[string]any{
		"startsAt": f.now.Add(24 * time.Hour).Format(time.RFC3339),
		"endsAt":   f.now.Add(48 * time.Hour).Format(time.RFC3339),
		"reason":   "training",
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("add: %d body=%s", resp.StatusCode, body)
	}
	resp, body = f.do("GET", "/instructors/user_instr/time-off", nil, f.adminToken)
	if !strings.Contains(string(body), "training") {
		t.Errorf("expected reason in list, got %s", body)
	}
}

func TestAvailability_TimeOff_RejectsInvertedRange(t *testing.T) {
	f := newLedgerFixture(t)
	resp, _ := f.do("POST", "/instructors/user_instr/time-off", map[string]any{
		"startsAt": f.now.Add(48 * time.Hour).Format(time.RFC3339),
		"endsAt":   f.now.Add(24 * time.Hour).Format(time.RFC3339),
	}, f.adminToken)
	if resp.StatusCode != 400 {
		t.Errorf("expected 400, got %d", resp.StatusCode)
	}
}
