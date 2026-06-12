// Package analytics aggregates operational metrics for the manager
// dashboard at /admin/analytics. Read-only — every function takes a
// (scope, from, to) window and returns a typed DTO ready for the
// HTTP layer to JSON-encode.
//
// Revenue + ageing live in `internal/revenue` (already wired into
// /admin/finance); analytics deliberately does not duplicate them.
//
// Time bucketing follows the existing pattern in `revenue`:
// substr-the-ISO-string for month keys, RFC3339 UTC throughout.
package analytics

import (
	"fmt"
	"time"
)

// Window normalises the (from, to) inputs every analytics function
// takes. `to` is exclusive — events at exactly `to` fall into the
// next bucket. Defaults: last 30 days ending now.
type Window struct {
	From time.Time
	To   time.Time
}

// NewWindow returns a window with sensible defaults. Either input
// can be zero — they get filled in. `from` defaults to 30 days
// before `to`; `to` defaults to the current UTC instant. If `from`
// is after `to`, they get swapped.
func NewWindow(from, to time.Time) Window {
	if to.IsZero() {
		to = time.Now().UTC()
	}
	if from.IsZero() {
		from = to.AddDate(0, 0, -30)
	}
	if from.After(to) {
		from, to = to, from
	}
	return Window{From: from.UTC(), To: to.UTC()}
}

// DaysIncl returns the inclusive day count covered by the window —
// used by utilisation maths that need a per-day denominator.
func (w Window) DaysIncl() int {
	d := w.To.Sub(w.From).Hours() / 24.0
	if d < 1 {
		return 1
	}
	return int(d + 0.5)
}

// fromISO + toISO are the column-compatible RFC3339 strings the
// queries paste into BETWEEN clauses.
func (w Window) fromISO() string { return w.From.UTC().Format(time.RFC3339) }
func (w Window) toISO() string   { return w.To.UTC().Format(time.RFC3339) }

// Helper for SQL errors so each query body stays a one-liner return.
func wrap(label string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("analytics %s: %w", label, err)
}
