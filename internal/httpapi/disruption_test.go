package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestDisruption_TakeBikeOfflineEndToEnd(t *testing.T) {
	f := newLedgerFixture(t)

	// Book a student onto the seeded session so there's a booking to disrupt.
	studentTok := f.loginStudent()
	resp, body := f.do("POST", "/bookings", map[string]string{"sessionId": "sess_t"}, studentTok)
	if resp.StatusCode != 201 {
		t.Fatalf("book: %d body=%s", resp.StatusCode, body)
	}
	var b struct{ Booking struct{ ID string } }
	json.Unmarshal(body, &b)

	// Add a spare A1 bike to make a swap possible.
	if _, err := f.db.Exec(`INSERT INTO bikes (id, school_id, category, transmission, status, home_location_id, current_location_id, created_at)
	                       VALUES ('bike_spare','school_t','A1','manual','ready','loc_t','loc_t',?)`,
		f.now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}

	// Admin takes the booked bike offline (no startsAt → defaults to now).
	resp, body = f.do("POST", "/bikes/bike_t/offline",
		map[string]any{"reason": "damaged", "notes": "front brake failed"},
		f.adminToken)
	if resp.StatusCode != 201 {
		t.Fatalf("offline: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"swapCandidates"`) {
		t.Errorf("expected swapCandidates in response, got %s", body)
	}
	if !strings.Contains(string(body), `"bike_spare"`) {
		t.Errorf("expected spare bike in candidate list, got %s", body)
	}

	// Parse out the disruption + affected booking IDs.
	var d struct {
		DisruptionID     string `json:"disruptionId"`
		AffectedBookings []struct {
			BookingID string `json:"bookingId"`
		} `json:"affectedBookings"`
	}
	if err := json.Unmarshal(body, &d); err != nil {
		t.Fatal(err)
	}
	if len(d.AffectedBookings) != 1 {
		t.Fatalf("expected 1 affected booking, got %d", len(d.AffectedBookings))
	}

	// Resolve via swap.
	resp, body = f.do("POST",
		"/disruptions/"+d.DisruptionID+"/bookings/"+d.AffectedBookings[0].BookingID+"/resolve",
		map[string]any{"resolution": "swapped", "newBikeId": "bike_spare"},
		f.adminToken)
	if resp.StatusCode != 204 {
		t.Errorf("resolve: %d body=%s", resp.StatusCode, body)
	}

	// Booking should now reference the spare bike.
	var newBike string
	if err := f.db.QueryRow(`SELECT bike_id FROM bookings WHERE id = ?`, b.Booking.ID).Scan(&newBike); err != nil {
		t.Fatal(err)
	}
	if newBike != "bike_spare" {
		t.Errorf("expected bike swapped to spare, got %q", newBike)
	}
}

func TestDisruption_StudentBlocked(t *testing.T) {
	f := newLedgerFixture(t)
	studentTok := f.loginStudent()
	resp, _ := f.do("POST", "/bikes/bike_t/offline",
		map[string]any{"reason": "damaged"}, studentTok)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403, got %d", resp.StatusCode)
	}
}

func TestDisruption_InstructorCanTakeOffline_AdminResolves(t *testing.T) {
	// In-field: an instructor can take a bike offline mid-day, then a
	// manager resolves the affected bookings.
	f := newLedgerFixture(t)
	instructor := f.loginAs("instr@test")
	resp, body := f.do("POST", "/bikes/bike_t/offline",
		map[string]any{"reason": "broken"}, instructor)
	if resp.StatusCode != 201 {
		t.Errorf("expected instructor can take offline, got %d body=%s", resp.StatusCode, body)
	}
}

func TestDisruption_InstructorCannotResolve(t *testing.T) {
	f := newLedgerFixture(t)
	instructor := f.loginAs("instr@test")
	resp, body := f.do("POST", "/bikes/bike_t/offline", map[string]any{"reason": "broken"}, instructor)
	if resp.StatusCode != 201 {
		t.Fatalf("offline: %d body=%s", resp.StatusCode, body)
	}
	var d struct {
		DisruptionID     string `json:"disruptionId"`
		AffectedBookings []struct {
			BookingID string `json:"bookingId"`
		} `json:"affectedBookings"`
	}
	json.Unmarshal(body, &d)
	// No affected bookings here (no one booked), so synthesise a path with a fake booking.
	resp, _ = f.do("POST",
		"/disruptions/"+d.DisruptionID+"/bookings/anything/resolve",
		map[string]any{"resolution": "cancel_with_approval"}, instructor)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for instructor resolve, got %d", resp.StatusCode)
	}
}
