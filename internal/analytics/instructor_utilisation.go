package analytics

import (
	"context"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// InstructorUtilisationRow aggregates one instructor's activity in
// the window plus a snapshot of what the school still owes them
// (all-time, matching the existing /admin/instructor-pay view).
type InstructorUtilisationRow struct {
	InstructorID     string
	Name             string
	SessionsTaught   int
	HoursTaughtX10   int   // tenths of an hour so JSON stays integer
	EarnedPence      int64 // sum of in-window non-voided earnings
	PaidPence        int64 // sum of in-window payments
	OutstandingPence int64 // ALL-time snapshot (earnings − payments), not window-scoped
	WeeklyTrend      []int // 8 buckets of sessions/week ending at window.To
}

// InstructorUtilisation computes per-instructor activity for the
// window. Excludes cancelled sessions and voided earnings. Uses the
// existing instructor-pay aggregation semantics for the outstanding
// snapshot so the two screens agree.
func InstructorUtilisation(ctx context.Context, scope *tenant.Scope, w Window) ([]InstructorUtilisationRow, error) {
	const q = `
		SELECT
			u.id,
			COALESCE(u.name, COALESCE(u.email, u.id)),
			COUNT(DISTINCT s.id) AS sessions_taught,
			COALESCE(SUM(
				CAST(strftime('%s', s.ends_at) AS INTEGER) -
				CAST(strftime('%s', s.starts_at) AS INTEGER)
			), 0) AS taught_secs,
			COALESCE(earned.amt, 0) AS earned_pence,
			COALESCE(paid.amt, 0) AS paid_pence,
			COALESCE(snapshot_earned.amt, 0) - COALESCE(snapshot_paid.amt, 0) AS outstanding_pence
		FROM users u
		LEFT JOIN sessions s
			ON s.instructor_id = u.id
			AND s.school_id = u.school_id
			AND s.status != 'cancelled'
			AND s.starts_at >= ?
			AND s.starts_at < ?
		LEFT JOIN (
			SELECT instructor_id, SUM(amount_pence) AS amt
			FROM instructor_earnings
			WHERE school_id = ? AND voided_at IS NULL
			  AND created_at >= ? AND created_at < ?
			GROUP BY instructor_id
		) earned ON earned.instructor_id = u.id
		LEFT JOIN (
			SELECT instructor_id, SUM(amount_pence) AS amt
			FROM instructor_payments
			WHERE school_id = ?
			  AND paid_at >= ? AND paid_at < ?
			GROUP BY instructor_id
		) paid ON paid.instructor_id = u.id
		LEFT JOIN (
			SELECT instructor_id, SUM(amount_pence) AS amt
			FROM instructor_earnings
			WHERE school_id = ? AND voided_at IS NULL
			GROUP BY instructor_id
		) snapshot_earned ON snapshot_earned.instructor_id = u.id
		LEFT JOIN (
			SELECT instructor_id, SUM(amount_pence) AS amt
			FROM instructor_payments
			WHERE school_id = ?
			GROUP BY instructor_id
		) snapshot_paid ON snapshot_paid.instructor_id = u.id
		WHERE u.school_id = ? AND u.role = 'instructor'
		GROUP BY u.id
		ORDER BY sessions_taught DESC, u.name ASC
	`
	schoolID := string(scope.SchoolID())
	fromS, toS := w.fromISO(), w.toISO()
	rows, err := scope.Conn().QueryContext(ctx, q,
		fromS, toS,
		schoolID, fromS, toS,
		schoolID, fromS, toS,
		schoolID,
		schoolID,
		schoolID,
	)
	if err != nil {
		return nil, wrap("instructor utilisation", err)
	}
	defer rows.Close()
	var out []InstructorUtilisationRow
	for rows.Next() {
		var r InstructorUtilisationRow
		var taughtSecs int64
		if err := rows.Scan(&r.InstructorID, &r.Name, &r.SessionsTaught,
			&taughtSecs, &r.EarnedPence, &r.PaidPence, &r.OutstandingPence); err != nil {
			return nil, wrap("scan instructor row", err)
		}
		r.HoursTaughtX10 = int(taughtSecs * 10 / 3600)
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Weekly trend — 8 buckets of week-ending counts, oldest first.
	if err := fillInstructorWeeklyTrend(ctx, scope, w, out); err != nil {
		return nil, err
	}
	return out, nil
}

// fillInstructorWeeklyTrend stitches an 8-week sessions-per-week
// series onto each row. One round-trip total (the buckets are filled
// in by string-comparing session starts_at against the bucket
// boundaries). Empty bucket = 0; instructors with no sessions get all
// zeros so the sparkline still renders.
func fillInstructorWeeklyTrend(ctx context.Context, scope *tenant.Scope, w Window, rows []InstructorUtilisationRow) error {
	const buckets = 8
	week := 7 * 24 * 60 * 60
	endSec := w.To.Unix()
	startSec := endSec - int64(buckets*week)

	indexByID := map[string]int{}
	for i := range rows {
		rows[i].WeeklyTrend = make([]int, buckets)
		indexByID[rows[i].InstructorID] = i
	}

	const q = `
		SELECT instructor_id, CAST(strftime('%s', starts_at) AS INTEGER) AS sec
		FROM sessions
		WHERE school_id = ?
		  AND status != 'cancelled'
		  AND starts_at >= ?
		  AND starts_at < ?
	`
	res, err := scope.Conn().QueryContext(ctx, q,
		string(scope.SchoolID()),
		time.Unix(startSec, 0).UTC().Format(time.RFC3339),
		w.toISO(),
	)
	if err != nil {
		return wrap("weekly trend", err)
	}
	defer res.Close()
	for res.Next() {
		var instID string
		var sec int64
		if err := res.Scan(&instID, &sec); err != nil {
			return err
		}
		idx, ok := indexByID[instID]
		if !ok {
			continue
		}
		bucket := int((sec - startSec) / int64(week))
		if bucket < 0 {
			bucket = 0
		}
		if bucket >= buckets {
			bucket = buckets - 1
		}
		rows[idx].WeeklyTrend[bucket]++
	}
	return res.Err()
}
