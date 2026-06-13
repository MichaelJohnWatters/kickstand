package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// POST /bikes/{id}/gps records a fix on the snapshot AND appends a
// history row. GET /bikes/{id}/gps/history reads them back in DESC
// order. Together they're the live-map's breadcrumb-trail feature.
func TestBikeGPS_HistoryAccumulates(t *testing.T) {
	f := newLedgerFixture(t)

	post := func(lat, lng float64) {
		resp, body := f.do("POST", "/bikes/bike_t/gps",
			map[string]any{"lat": lat, "lng": lng}, f.adminToken)
		if resp.StatusCode != http.StatusNoContent {
			t.Fatalf("POST gps: %d body=%s", resp.StatusCode, body)
		}
	}

	post(54.6, -5.9)
	post(54.61, -5.91)
	post(54.62, -5.92)

	resp, body := f.do("GET", "/bikes/bike_t/gps/history", nil, f.adminToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET history: %d body=%s", resp.StatusCode, body)
	}
	var out struct {
		Fixes []struct {
			At  string  `json:"at"`
			Lat float64 `json:"lat"`
			Lng float64 `json:"lng"`
		} `json:"fixes"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("decode: %v body=%s", err, body)
	}
	if len(out.Fixes) != 3 {
		t.Fatalf("expected 3 fixes, got %d body=%s", len(out.Fixes), body)
	}
	// Newest-first ordering: the lat we posted last must come first.
	if out.Fixes[0].Lat != 54.62 {
		t.Errorf("expected newest lat 54.62 first, got %v", out.Fixes[0].Lat)
	}
	if out.Fixes[2].Lat != 54.6 {
		t.Errorf("expected oldest lat 54.6 last, got %v", out.Fixes[2].Lat)
	}
	// Every row carries an RFC3339 timestamp.
	if _, err := time.Parse(time.RFC3339, out.Fixes[0].At); err != nil {
		t.Errorf("at not RFC3339: %v", err)
	}
}

// A fix more than 200km from every geocoded school site is refused.
// The seed planted Belfast (loc_t) at 54.5825/-5.9655, so a London
// coordinate (~518 km away) trips the proximity check.
//
// When no location carries lat/lng the check is skipped (graceful
// degrade). The base seed leaves loc_t without coords, so we set
// them inline to switch the check on for this test.
func TestBikeGPS_ProximityRejectsFarAwayFix(t *testing.T) {
	f := newLedgerFixture(t)
	if _, err := f.db.Exec(
		`UPDATE locations SET lat = 54.5825, lng = -5.9655 WHERE id = 'loc_t'`,
	); err != nil {
		t.Fatalf("set loc coords: %v", err)
	}
	// London → ~518 km from Belfast: refused.
	resp, body := f.do("POST", "/bikes/bike_t/gps",
		map[string]any{"lat": 51.5074, "lng": -0.1278}, f.adminToken)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for out-of-range fix, got %d body=%s", resp.StatusCode, body)
	}
	// Near Belfast → accepted.
	resp, body = f.do("POST", "/bikes/bike_t/gps",
		map[string]any{"lat": 54.59, "lng": -5.96}, f.adminToken)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204 for near-site fix, got %d body=%s", resp.StatusCode, body)
	}
}

// The since filter trims older rows. A future-dated lower bound
// returns no fixes; an open lower bound returns everything.
func TestBikeGPS_HistorySinceFilter(t *testing.T) {
	f := newLedgerFixture(t)
	for _, lat := range []float64{54.50, 54.51, 54.52} {
		resp, _ := f.do("POST", "/bikes/bike_t/gps",
			map[string]any{"lat": lat, "lng": -6.0}, f.adminToken)
		if resp.StatusCode != http.StatusNoContent {
			t.Fatalf("seed fix lat=%v: %d", lat, resp.StatusCode)
		}
	}
	future := time.Now().UTC().Add(time.Hour).Format(time.RFC3339)
	resp, body := f.do("GET",
		"/bikes/bike_t/gps/history?since="+future, nil, f.adminToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET filtered: %d body=%s", resp.StatusCode, body)
	}
	var out struct {
		Fixes []map[string]any `json:"fixes"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("decode: %v body=%s", err, body)
	}
	if len(out.Fixes) != 0 {
		t.Fatalf("expected no fixes with future since, got %d", len(out.Fixes))
	}
}
