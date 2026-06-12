package admin

import (
	"testing"
	"time"
)

func TestComputeWarning(t *testing.T) {
	const (
		warn   = 90
		urgent = 14
	)
	today := time.Date(2026, 6, 8, 12, 0, 0, 0, time.UTC)
	mkExpiry := func(daysFromNow int) time.Time {
		return today.AddDate(0, 0, daysFromNow)
	}

	tests := []struct {
		name      string
		expiry    time.Time
		expirySet bool
		want      WarningStatus
	}{
		{"unknown when no expiry set", time.Time{}, false, WarnUnknown},
		{"expired one day ago", mkExpiry(-1), true, WarnExpired},
		{"expired today (boundary)", today, true, WarnExpired},
		{"urgent — one day to go", mkExpiry(1), true, WarnDueUrgent},
		{"urgent — at urgent boundary", mkExpiry(urgent), true, WarnDueUrgent},
		{"due soon — just past urgent", mkExpiry(urgent + 1), true, WarnDueSoon},
		{"due soon — at warn boundary", mkExpiry(warn), true, WarnDueSoon},
		{"ok — just past warn", mkExpiry(warn + 1), true, WarnOK},
		{"ok — far in the future", mkExpiry(365), true, WarnOK},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ComputeWarning(today, tc.expiry, tc.expirySet, warn, urgent)
			if got != tc.want {
				t.Errorf("got %q want %q (expiry=%v expirySet=%v)",
					got, tc.want, tc.expiry, tc.expirySet)
			}
		})
	}
}

func TestComputeWarning_CustomWindows(t *testing.T) {
	today := time.Date(2026, 6, 8, 0, 0, 0, 0, time.UTC)
	// Custom: tight tax windows.
	const warn, urgent = 30, 7
	cases := []struct {
		days int
		want WarningStatus
	}{
		{45, WarnOK},
		{15, WarnDueSoon},
		{5, WarnDueUrgent},
		{0, WarnExpired},
	}
	for _, c := range cases {
		got := ComputeWarning(today, today.AddDate(0, 0, c.days), true, warn, urgent)
		if got != c.want {
			t.Errorf("days=%d got %q want %q", c.days, got, c.want)
		}
	}
}

func TestParseExpiry(t *testing.T) {
	got, ok, err := ParseExpiry("2026-09-12")
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Error("expected non-empty parse to return ok=true")
	}
	if got.Year() != 2026 || got.Month() != 9 || got.Day() != 12 {
		t.Errorf("bad date: %v", got)
	}

	_, ok, err = ParseExpiry("")
	if err != nil {
		t.Errorf("empty should return err=nil, got %v", err)
	}
	if ok {
		t.Error("empty should return ok=false")
	}

	_, _, err = ParseExpiry("not a date")
	if err == nil {
		t.Error("expected parse error")
	}
}
