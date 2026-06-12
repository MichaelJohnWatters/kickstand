package admin

import (
	"testing"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// deriveLiveStatus collapses the DB status enum + a runtime
// "currently in a session" flag into the marker bucket. Pure function
// — no DB needed.
func TestDeriveLiveStatus(t *testing.T) {
	tests := []struct {
		name      string
		dbStatus  domain.BikeStatus
		inSession bool
		want      string
	}{
		{"offline DB row stays offline regardless of session", "offline", false, "offline"},
		{"offline beats in_session", "offline", true, "offline"},
		{"in_use DB status with a live session → in_session", "in_use", true, "in_session"},
		{"in_use DB status without a live session → needs_attention", "in_use", false, "needs_attention"},
		{"ready + no session → available", "ready", false, "available"},
		{"ready but a live session running → in_session", "ready", true, "in_session"},
		{"casing tolerated", "READY", false, "available"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := deriveLiveStatus(tc.dbStatus, tc.inSession)
			if got != tc.want {
				t.Errorf("got %q want %q", got, tc.want)
			}
		})
	}
}

// UpdateBikeGPS coordinate validation. Pure input check, no DB
// interaction beyond a stub scope — but the validation runs before
// any SQL, so a nil scope is fine for the failing branches.
func TestUpdateBikeGPS_CoordValidation(t *testing.T) {
	cases := []struct {
		name    string
		lat     float64
		lng     float64
		wantErr bool
	}{
		{"lat too low", -91, 0, true},
		{"lat too high", 91, 0, true},
		{"lng too low", 0, -181, true},
		{"lng too high", 0, 181, true},
		{"valid NI coords", 54.6, -5.9, false},
		{"valid antipode", -54.6, 174.1, false},
		{"zero is valid", 0, 0, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// We only assert the validation branch. A nil scope would
			// panic past the guards, so good cases get skipped here —
			// they're exercised by the HTTP-level tests.
			if !tc.wantErr {
				return
			}
			err := UpdateBikeGPS(nil, nil, "any", UpdateBikeGPSRequest{Lat: tc.lat, Lng: tc.lng})
			if err == nil {
				t.Fatalf("expected validation error for lat=%v lng=%v", tc.lat, tc.lng)
			}
		})
	}
}
