package analytics

import (
	"context"

	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// BikeUtilisationRow is one bike's activity for the window. Sorted
// descending by utilisation pct so the most-worked bikes lead.
type BikeUtilisationRow struct {
	BikeID           string
	Nickname         string
	Registration     string
	SessionsCount    int
	BookedMinutes    int
	AvailableMinutes int     // window days × 8h, simple v1 denominator
	UtilisationPct   float64 // 0..100
	LastSessionAt    string  // RFC3339 of most recent eligible session; empty if none
}

// BikeUtilisation computes per-bike utilisation in the window.
//
// "Booked" minutes = sum of session durations for sessions where this
// bike was assigned to a non-cancelled, non-no-show booking that
// landed on a non-cancelled session whose start time falls in the
// window.
//
// "Available" minutes use a simple v1 denominator: window days × 8h.
// That's deliberately rough — a real "available" number would need
// per-bike scheduled availability windows. The current model errs on
// the low side (most schools don't run 8h × every day), which gives
// utilisation pcts that can exceed 100 for popular bikes — and
// that's a useful signal in itself.
func BikeUtilisation(ctx context.Context, scope *tenant.Scope, w Window) ([]BikeUtilisationRow, error) {
	const dailyMinutes = 8 * 60
	availableMinutes := w.DaysIncl() * dailyMinutes

	// CTE first dedupes to (bike, session) pairs so a session shared
	// by N students on the same bike still counts as one occupancy
	// block. The outer query then aggregates per bike.
	const q = `
		WITH bike_sessions AS (
			SELECT DISTINCT
				bk.bike_id,
				s.id AS session_id,
				s.starts_at,
				(CAST(strftime('%s', s.ends_at) AS INTEGER) -
				 CAST(strftime('%s', s.starts_at) AS INTEGER)) / 60 AS duration_min
			FROM bookings bk
			JOIN sessions s
				ON s.id = bk.session_id
				AND s.school_id = bk.school_id
			WHERE bk.bike_id IS NOT NULL
				AND bk.school_id = ?
				AND bk.status NOT IN ('cancelled', 'no_show', 'needs_reassignment')
				AND s.status != 'cancelled'
				AND s.starts_at >= ?
				AND s.starts_at < ?
		)
		SELECT
			b.id,
			COALESCE(b.nickname, ''),
			COALESCE(b.registration, ''),
			COUNT(bs.session_id) AS sessions_count,
			COALESCE(SUM(bs.duration_min), 0) AS booked_minutes,
			COALESCE(MAX(bs.starts_at), '') AS last_session_at
		FROM bikes b
		LEFT JOIN bike_sessions bs ON bs.bike_id = b.id
		WHERE b.school_id = ?
		GROUP BY b.id
		ORDER BY booked_minutes DESC, b.nickname ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q,
		string(scope.SchoolID()), w.fromISO(), w.toISO(),
		string(scope.SchoolID()))
	if err != nil {
		return nil, wrap("bike utilisation", err)
	}
	defer rows.Close()
	var out []BikeUtilisationRow
	for rows.Next() {
		var r BikeUtilisationRow
		if err := rows.Scan(&r.BikeID, &r.Nickname, &r.Registration,
			&r.SessionsCount, &r.BookedMinutes, &r.LastSessionAt); err != nil {
			return nil, wrap("scan bike row", err)
		}
		r.AvailableMinutes = availableMinutes
		if availableMinutes > 0 {
			r.UtilisationPct = float64(r.BookedMinutes) / float64(availableMinutes) * 100
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
