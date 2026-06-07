package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestMyBookings_StudentSeesOwn(t *testing.T) {
	f := newLedgerFixture(t)
	stu := f.loginStudent()
	if resp, _ := f.do("POST", "/bookings",
		map[string]string{"sessionId": "sess_t"}, stu); resp.StatusCode != 201 {
		t.Fatal("book")
	}

	resp, body := f.do("GET", "/me/bookings?when=upcoming", nil, stu)
	if resp.StatusCode != 200 {
		t.Fatalf("list: %d body=%s", resp.StatusCode, body)
	}
	var out struct {
		Bookings []struct {
			Status     string `json:"status"`
			CourseName string `json:"courseName"`
		} `json:"bookings"`
	}
	json.Unmarshal(body, &out)
	if len(out.Bookings) != 1 || out.Bookings[0].Status != "booked" {
		t.Errorf("unexpected: %s", body)
	}
}

func TestMyBookings_StaffRejected(t *testing.T) {
	f := newLedgerFixture(t)
	resp, _ := f.do("GET", "/me/bookings", nil, f.adminToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 (staff use /students/{id}/bookings), got %d", resp.StatusCode)
	}
}

func TestMyBookings_PastFilter_IncludesCancelled(t *testing.T) {
	f := newLedgerFixture(t)
	stu := f.loginStudent()
	resp, body := f.do("POST", "/bookings", map[string]string{"sessionId": "sess_t"}, stu)
	if resp.StatusCode != 201 {
		t.Fatal("book")
	}
	var b struct{ Booking struct{ ID string } }
	json.Unmarshal(body, &b)
	if resp, _ := f.do("DELETE", "/bookings/"+b.Booking.ID, nil, stu); resp.StatusCode != 200 {
		t.Fatal("cancel")
	}

	// upcoming = 0
	_, body = f.do("GET", "/me/bookings?when=upcoming", nil, stu)
	if !strings.Contains(string(body), `"bookings":[]`) {
		t.Errorf("expected empty upcoming after cancel, got %s", body)
	}
	// past = 1, with cancelled status + reason fields
	_, body = f.do("GET", "/me/bookings?when=past", nil, stu)
	if !strings.Contains(string(body), `"status":"cancelled"`) {
		t.Errorf("expected cancelled in past, got %s", body)
	}
}

func TestStudentBookings_StaffViewAny(t *testing.T) {
	f := newLedgerFixture(t)
	stu := f.loginStudent()
	if resp, _ := f.do("POST", "/bookings",
		map[string]string{"sessionId": "sess_t"}, stu); resp.StatusCode != 201 {
		t.Fatal("book")
	}
	resp, body := f.do("GET", "/students/user_stu/bookings", nil, f.adminToken)
	if resp.StatusCode != 200 || !strings.Contains(string(body), `"courseName":"CBT 125"`) {
		t.Errorf("staff list: %d body=%s", resp.StatusCode, body)
	}
}

func TestMyStudentProfile_Renders(t *testing.T) {
	f := newLedgerFixture(t)
	stu := f.loginStudent()
	resp, body := f.do("GET", "/me/student-profile", nil, stu)
	if resp.StatusCode != 200 {
		t.Fatalf("profile: %d body=%s", resp.StatusCode, body)
	}
	for _, k := range []string{"transmissionPreference", "cbtHeld", "theoryPassed", "schoolRegion", "testBodyLabel"} {
		if !strings.Contains(string(body), k) {
			t.Errorf("expected %s in profile response, got %s", k, body)
		}
	}
	if !strings.Contains(string(body), `"schoolRegion":"NI"`) {
		t.Errorf("expected NI region, got %s", body)
	}
}

func TestMyStudentProfile_StaffRejected(t *testing.T) {
	f := newLedgerFixture(t)
	resp, _ := f.do("GET", "/me/student-profile", nil, f.adminToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}
