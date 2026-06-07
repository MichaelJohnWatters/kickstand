package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// Progress endpoints reuse the ledger fixture (admin + instructor + student
// users + seeded session). We additionally seed competencies and a booking.

type progFixture struct {
	*ledgerFixture
	instructor string
	studentTok string
	bookingID  string
}

func newProgressFixture(t *testing.T) *progFixture {
	t.Helper()
	f := newLedgerFixture(t)

	// Add a competency to the seeded course.
	if _, err := f.db.Exec(`INSERT INTO competencies (id, school_id, course_type_id, label, sort_order)
	                       VALUES ('comp_uturn', 'school_t', 'ct_cbt', 'U-turn', 1)`); err != nil {
		t.Fatal(err)
	}
	// Make a booking for the seeded student.
	stuTok := f.loginStudent()
	resp, body := f.do("POST", "/bookings", map[string]string{"sessionId": "sess_t"}, stuTok)
	if resp.StatusCode != 201 {
		t.Fatalf("seed booking: %d body=%s", resp.StatusCode, body)
	}
	var b struct{ Booking struct{ ID string } }
	json.Unmarshal(body, &b)

	pf := &progFixture{
		ledgerFixture: f,
		instructor:    f.loginAs("instr@test"),
		studentTok:    stuTok,
		bookingID:     b.Booking.ID,
	}
	return pf
}

// ----- Tests -----

func TestProgressHTTP_MarkAttendance_Instructor(t *testing.T) {
	f := newProgressFixture(t)
	resp, body := f.do("POST", "/bookings/"+f.bookingID+"/attendance",
		map[string]string{"status": "completed"}, f.instructor)
	if resp.StatusCode != 204 {
		t.Errorf("attendance: %d body=%s", resp.StatusCode, body)
	}
}

func TestProgressHTTP_MarkAttendance_StudentRejected(t *testing.T) {
	f := newProgressFixture(t)
	resp, _ := f.do("POST", "/bookings/"+f.bookingID+"/attendance",
		map[string]string{"status": "completed"}, f.studentTok)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestProgressHTTP_AssessCompetency(t *testing.T) {
	f := newProgressFixture(t)
	resp, body := f.do("PUT",
		"/bookings/"+f.bookingID+"/competencies/comp_uturn",
		map[string]string{"status": "competent"}, f.instructor)
	if resp.StatusCode != 200 {
		t.Fatalf("assess: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"status":"competent"`) {
		t.Errorf("expected competent status in response, got %s", body)
	}
}

func TestProgressHTTP_AssessCompetency_OtherInstructorRejected(t *testing.T) {
	f := newProgressFixture(t)
	// Create a second instructor in the same school using the fixture
	// password so loginAs works.
	resp, _ := f.do("POST", "/instructors", map[string]any{
		"name": "Other", "email": "other@test.com", "password": f.password,
		"homeLocationId": "loc_t", "qualifiedCourseIds": []string{"ct_cbt"},
	}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatal("invite")
	}
	otherTok := f.loginAs("other@test.com")
	resp, _ = f.do("PUT",
		"/bookings/"+f.bookingID+"/competencies/comp_uturn",
		map[string]string{"status": "competent"}, otherTok)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 (not assigned instructor), got %d", resp.StatusCode)
	}
}

func TestProgressHTTP_AdminCanAssessAnySession(t *testing.T) {
	f := newProgressFixture(t)
	resp, body := f.do("PUT",
		"/bookings/"+f.bookingID+"/competencies/comp_uturn",
		map[string]string{"status": "developing"}, f.adminToken)
	if resp.StatusCode != 200 {
		t.Errorf("admin assess: %d body=%s", resp.StatusCode, body)
	}
}

func TestProgressHTTP_SetBookingNotes(t *testing.T) {
	f := newProgressFixture(t)
	resp, _ := f.do("PUT", "/bookings/"+f.bookingID+"/notes",
		map[string]string{"notes": "strong rider, needs roundabouts"}, f.instructor)
	if resp.StatusCode != 204 {
		t.Errorf("notes: %d", resp.StatusCode)
	}
}

func TestProgressHTTP_GetSessionDetail(t *testing.T) {
	f := newProgressFixture(t)
	// Add a safety flag and a charge so detail shows both.
	if _, err := f.db.Exec(`INSERT INTO student_notes (id, school_id, student_id, kind, body, is_active, created_at, created_by)
	                       VALUES ('n1', 'school_t', 'user_stu', 'safety_flag', 'Low seat required', 1, ?, 'user_admin')`,
		f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	resp, _ := f.do("POST", "/students/user_stu/charges",
		map[string]any{"amountPence": 13000, "description": "CBT"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatal("seed charge")
	}

	resp, body := f.do("GET", "/sessions/sess_t/detail", nil, f.instructor)
	if resp.StatusCode != 200 {
		t.Fatalf("detail: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "Low seat required") {
		t.Errorf("expected safety flag in detail, got %s", body)
	}
	if !strings.Contains(string(body), `"outstandingPence":13000`) {
		t.Errorf("expected outstanding 13000, got %s", body)
	}
	if !strings.Contains(string(body), "U-turn") {
		t.Errorf("expected competency template U-turn, got %s", body)
	}
}

func TestProgressHTTP_GetSessionDetail_StudentRejected(t *testing.T) {
	f := newProgressFixture(t)
	resp, _ := f.do("GET", "/sessions/sess_t/detail", nil, f.studentTok)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestProgressHTTP_GetStudentProgress_OwnView(t *testing.T) {
	f := newProgressFixture(t)
	// Assess the competency first.
	resp, _ := f.do("PUT",
		"/bookings/"+f.bookingID+"/competencies/comp_uturn",
		map[string]string{"status": "competent"}, f.instructor)
	if resp.StatusCode != 200 {
		t.Fatal("assess")
	}
	resp, body := f.do("GET", "/students/user_stu/progress", nil, f.studentTok)
	if resp.StatusCode != 200 {
		t.Fatalf("progress: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"competentCount":1`) {
		t.Errorf("expected competentCount 1, got %s", body)
	}
}

func TestProgressHTTP_GetStudentProgress_OtherStudentRejected(t *testing.T) {
	f := newProgressFixture(t)
	// Sign up a second student and try to peek at the first.
	resp, body := f.do("POST", "/auth/signup", map[string]any{
		"schoolId": "school_t", "name": "Sneaky", "email": "sneaky@test.com",
		"password": "longenoughpw", "transmissionPreference": "manual",
		"licenceCategoryPursued": "A2",
	}, "")
	if resp.StatusCode != 201 {
		t.Fatalf("signup: %d body=%s", resp.StatusCode, body)
	}
	var sig struct{ Token string }
	json.Unmarshal(body, &sig)
	resp, _ = f.do("GET", "/students/user_stu/progress", nil, sig.Token)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}
