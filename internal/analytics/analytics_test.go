package analytics

import (
	"testing"
	"time"
)

func TestNewWindow_DefaultsToLast30Days(t *testing.T) {
	w := NewWindow(time.Time{}, time.Time{})
	gotDays := w.DaysIncl()
	if gotDays < 29 || gotDays > 31 {
		t.Errorf("expected ~30 days, got %d", gotDays)
	}
	if w.From.After(w.To) {
		t.Errorf("from %v should be ≤ to %v", w.From, w.To)
	}
}

func TestNewWindow_SwapsReversedInputs(t *testing.T) {
	later := time.Date(2026, 6, 12, 0, 0, 0, 0, time.UTC)
	earlier := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	w := NewWindow(later, earlier)
	if w.From != earlier {
		t.Errorf("from should normalise to the earlier date, got %v", w.From)
	}
	if w.To != later {
		t.Errorf("to should normalise to the later date, got %v", w.To)
	}
}

func TestWindow_DaysIncl_Bounds(t *testing.T) {
	tests := []struct {
		name        string
		from        time.Time
		to          time.Time
		wantMinDays int
		wantMaxDays int
	}{
		{
			name:        "zero range collapses to 1 day",
			from:        time.Date(2026, 6, 12, 12, 0, 0, 0, time.UTC),
			to:          time.Date(2026, 6, 12, 12, 0, 0, 0, time.UTC),
			wantMinDays: 1,
			wantMaxDays: 1,
		},
		{
			name:        "7-day window",
			from:        time.Date(2026, 6, 5, 0, 0, 0, 0, time.UTC),
			to:          time.Date(2026, 6, 12, 0, 0, 0, 0, time.UTC),
			wantMinDays: 7,
			wantMaxDays: 7,
		},
		{
			name:        "rounds to nearest day",
			from:        time.Date(2026, 6, 5, 0, 0, 0, 0, time.UTC),
			to:          time.Date(2026, 6, 5, 23, 0, 0, 0, time.UTC),
			wantMinDays: 1,
			wantMaxDays: 1,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			w := Window{From: tc.from, To: tc.to}
			got := w.DaysIncl()
			if got < tc.wantMinDays || got > tc.wantMaxDays {
				t.Errorf("got %d days, want %d..%d", got, tc.wantMinDays, tc.wantMaxDays)
			}
		})
	}
}
