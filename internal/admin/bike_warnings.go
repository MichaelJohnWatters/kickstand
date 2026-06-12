package admin

import "time"

// WarningStatus is the bucket the fleet card paints for MOT and tax.
//
// Computed on read from (expiry date, today, warn-window, urgent-window) —
// never stored. School-level windows live on `schools.mot_warn_days`
// etc and come from SchoolSettings; defaults are the chunk-2
// fallback values when a school hasn't customised them.
type WarningStatus string

const (
	WarnUnknown    WarningStatus = "unknown"
	WarnOK         WarningStatus = "ok"
	WarnDueSoon    WarningStatus = "due_soon"
	WarnDueUrgent  WarningStatus = "due_urgent"
	WarnExpired    WarningStatus = "expired"
)

// Default warn/urgent windows (also the defaults baked into migration
// 0008). Re-exported so the engine can fall back when a school hasn't
// customised. Don't read these directly in handlers — call
// settingsFor(scope) and use those values so school overrides take
// effect.
const (
	DefaultMOTWarnDays   = 90
	DefaultMOTUrgentDays = 14
	DefaultTaxWarnDays   = 30
	DefaultTaxUrgentDays = 7
)

// ComputeWarning bucketises a parsed expiry date against today.
//
//   - empty expiry              → WarnUnknown
//   - expired                   → WarnExpired
//   - days remaining ≤ urgent   → WarnDueUrgent
//   - days remaining ≤ warn     → WarnDueSoon
//   - otherwise                 → WarnOK
//
// `warnDays` and `urgentDays` are positive integers; `urgentDays`
// should be <= warnDays. If they're given inverted the function still
// returns a sensible status (urgent takes precedence).
func ComputeWarning(today time.Time, expiry time.Time, expirySet bool, warnDays, urgentDays int) WarningStatus {
	if !expirySet {
		return WarnUnknown
	}
	// Compute days remaining at calendar granularity — partial days
	// would make the bucket flip-flop around midnight.
	t := time.Date(today.Year(), today.Month(), today.Day(), 0, 0, 0, 0, today.Location())
	e := time.Date(expiry.Year(), expiry.Month(), expiry.Day(), 0, 0, 0, 0, expiry.Location())
	days := int(e.Sub(t).Hours() / 24)
	switch {
	case days <= 0:
		return WarnExpired
	case days <= urgentDays:
		return WarnDueUrgent
	case days <= warnDays:
		return WarnDueSoon
	default:
		return WarnOK
	}
}

// ParseExpiry parses an ISO date (YYYY-MM-DD) and returns whether the
// input was non-empty + the parsed value. Empty input is the signal
// for "no expiry on file" — the WarningStatus pipeline maps that to
// WarnUnknown.
func ParseExpiry(s string) (time.Time, bool, error) {
	if s == "" {
		return time.Time{}, false, nil
	}
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return time.Time{}, false, err
	}
	return t, true, nil
}
