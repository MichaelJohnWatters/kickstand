package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestCalendar_ListsSeededSession(t *testing.T) {
	f := newLedgerFixture(t)
	from := f.now.Add(-time.Hour).Format(time.RFC3339)
	to := f.now.Add(7 * 24 * time.Hour).Format(time.RFC3339)
	resp, body := f.do("GET", "/calendar?from="+from+"&to="+to, nil, f.adminToken)
	if resp.StatusCode != 200 {
		t.Fatalf("calendar: %d body=%s", resp.StatusCode, body)
	}
	var out struct {
		Sessions []struct {
			SessionID      string `json:"sessionId"`
			InstructorID   string `json:"instructorId"`
			ActiveBookings int    `json:"activeBookings"`
		} `json:"sessions"`
		Warnings []map[string]any `json:"warnings"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Sessions) != 1 {
		t.Fatalf("expected 1 session, got %d", len(out.Sessions))
	}
	if out.Sessions[0].SessionID != "sess_t" {
		t.Errorf("expected sess_t, got %s", out.Sessions[0].SessionID)
	}
}

func TestCalendar_StudentRejected(t *testing.T) {
	f := newLedgerFixture(t)
	from := f.now.Format(time.RFC3339)
	to := f.now.Add(time.Hour).Format(time.RFC3339)
	resp, _ := f.do("GET", "/calendar?from="+from+"&to="+to, nil, f.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestCalendar_TravelWarningFiresWhenGapTooTight(t *testing.T) {
	f := newLedgerFixture(t)

	// Add a second location, set travel time 30 min between them.
	resp, body := f.do("POST", "/locations", map[string]any{"name": "Lisburn"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatal("loc")
	}
	var loc struct{ ID string }
	json.Unmarshal(body, &loc)
	if resp, _ := f.do("PUT", "/travel-times",
		map[string]any{"fromLocationId": "loc_t", "toLocationId": loc.ID, "minutes": 30},
		f.adminToken); resp.StatusCode != 204 {
		t.Fatal("set tt")
	}

	// Two consecutive sessions for the same instructor, different sites,
	// 10-min gap. Travel matrix says 30 min + default buffer 15 = 45 min
	// needed. Should warn.
	start1 := f.now.Add(48 * time.Hour).Format(time.RFC3339)
	end1 := f.now.Add(48*time.Hour + 1*time.Hour).Format(time.RFC3339)
	start2 := f.now.Add(48*time.Hour + 70*time.Minute).Format(time.RFC3339) // 10 min after end1
	end2 := f.now.Add(48*time.Hour + 130*time.Minute).Format(time.RFC3339)

	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := f.db.Exec(q, args...); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id,
	          starts_at, ends_at, capacity, created_at)
	      VALUES ('sess_a', 'school_t', 'ct_cbt', 'user_instr', 'loc_t', ?, ?, 1, ?)`,
		start1, end1, f.now.Format(time.RFC3339))
	exec(`INSERT INTO sessions (id, school_id, course_type_id, instructor_id, location_id,
	          starts_at, ends_at, capacity, created_at)
	      VALUES ('sess_b', 'school_t', 'ct_cbt', 'user_instr', ?, ?, ?, 1, ?)`,
		loc.ID, start2, end2, f.now.Format(time.RFC3339))

	from := f.now.Format(time.RFC3339)
	to := f.now.Add(72 * time.Hour).Format(time.RFC3339)
	resp, body = f.do("GET", "/calendar?from="+from+"&to="+to, nil, f.adminToken)
	if resp.StatusCode != 200 {
		t.Fatalf("calendar: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"travelMinutes":30`) {
		t.Errorf("expected travel warning with 30 min travel, got %s", body)
	}
	if !strings.Contains(string(body), `"fromSessionId":"sess_a"`) {
		t.Errorf("expected warning for sess_a → sess_b, got %s", body)
	}
}

// ----- Logistics -----

func TestLogistics_BikesAtWrongSite(t *testing.T) {
	f := newLedgerFixture(t)
	// Book the seeded session (bike is at loc_t, session is at loc_t — no
	// move needed yet).
	stu := f.loginStudent()
	if resp, _ := f.do("POST", "/bookings",
		map[string]string{"sessionId": "sess_t"}, stu); resp.StatusCode != 201 {
		t.Fatal("book")
	}

	// Add a second location and "move" the bike there so the session needs
	// a move.
	resp, body := f.do("POST", "/locations", map[string]any{"name": "Lisburn"}, f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatal("loc")
	}
	var loc struct{ ID string }
	json.Unmarshal(body, &loc)
	if _, err := f.db.Exec(`UPDATE bikes SET current_location_id = ? WHERE id = 'bike_t'`, loc.ID); err != nil {
		t.Fatal(err)
	}

	// The seeded session starts 24h from f.now. Query its date.
	dateStr := f.now.Add(24 * time.Hour).Format("2006-01-02")
	resp, body = f.do("GET", "/logistics?date="+dateStr, nil, f.adminToken)
	if resp.StatusCode != 200 {
		t.Fatalf("logistics: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"totalMoves":1`) {
		t.Errorf("expected totalMoves=1, got %s", body)
	}
	if !strings.Contains(string(body), `"bikeId":"bike_t"`) {
		t.Errorf("expected bike_t in moves, got %s", body)
	}
}

func TestLogistics_StudentRejected(t *testing.T) {
	f := newLedgerFixture(t)
	resp, _ := f.do("GET", "/logistics", nil, f.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestLogistics_BadDate(t *testing.T) {
	f := newLedgerFixture(t)
	resp, _ := f.do("GET", "/logistics?date=tomorrow", nil, f.adminToken)
	if resp.StatusCode != 400 {
		t.Errorf("expected 400, got %d", resp.StatusCode)
	}
}
