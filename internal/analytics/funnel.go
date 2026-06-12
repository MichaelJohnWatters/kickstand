package analytics

import (
	"context"

	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// FunnelStats answers four progression questions for the window.
// All percentages are 0..100 floats. `Sample` counts let the UI
// show "82% (28 of 34)" rather than a misleading "100% (1 of 1)".
type FunnelStats struct {
	SignupToFirstBookingPct     float64
	SignupSample                int
	CBTCompletionPct            float64
	CBTSample                   int
	TheoryPassPct               float64
	TheorySample                int
	PracticalPassPct            float64
	PracticalSample             int
	PerInstructorPassRate       []InstructorPassRate
}

// InstructorPassRate is per-instructor test outcomes attributed by
// "the student had a non-cancelled booking with this instructor in
// the 90 days before the test". Loose attribution; documented in
// `gps-and-analytics-plan.md` chunk 2 risks.
type InstructorPassRate struct {
	InstructorID string
	Name         string
	Attempts     int
	Passes       int
	PassPct      float64
}

// Funnel computes the four funnel stats + the per-instructor pass
// rate table for the given window.
func Funnel(ctx context.Context, scope *tenant.Scope, w Window) (FunnelStats, error) {
	var out FunnelStats
	if err := computeSignupConversion(ctx, scope, w, &out); err != nil {
		return out, err
	}
	if err := computeCBTCompletion(ctx, scope, w, &out); err != nil {
		return out, err
	}
	if err := computeTestPassRates(ctx, scope, w, &out); err != nil {
		return out, err
	}
	if err := computePerInstructorPassRates(ctx, scope, w, &out); err != nil {
		return out, err
	}
	return out, nil
}

// computeSignupConversion: of students who joined in the window, what
// fraction had at least one non-cancelled booking within 30 days of
// their signup? Approximation of "they actually started training."
func computeSignupConversion(ctx context.Context, scope *tenant.Scope, w Window, out *FunnelStats) error {
	const q = `
		SELECT
			COUNT(*) AS signup_count,
			COALESCE(SUM(CASE WHEN EXISTS (
				SELECT 1 FROM bookings b
				WHERE b.school_id = u.school_id
				  AND b.student_id = u.id
				  AND b.status != 'cancelled'
				  AND b.created_at <= datetime(u.created_at, '+30 days')
			) THEN 1 ELSE 0 END), 0) AS converted
		FROM users u
		WHERE u.school_id = ? AND u.role = 'student'
		  AND u.created_at >= ? AND u.created_at < ?
	`
	var total, converted int
	if err := scope.Conn().QueryRowContext(ctx, q,
		string(scope.SchoolID()), w.fromISO(), w.toISO(),
	).Scan(&total, &converted); err != nil {
		return wrap("signup conversion", err)
	}
	out.SignupSample = total
	if total > 0 {
		out.SignupToFirstBookingPct = float64(converted) / float64(total) * 100
	}
	return nil
}

// computeCBTCompletion: of students with a non-cancelled CBT booking
// in the window, what fraction reached status='completed' on that
// booking? CBT is identified by course type code starting with 'CBT'
// (NI: CBT-125, CBT-650; GB: CBT). Keep the WHERE loose so it
// doesn't fall over when a school renames their course types.
func computeCBTCompletion(ctx context.Context, scope *tenant.Scope, w Window, out *FunnelStats) error {
	const q = `
		SELECT
			COUNT(*) AS total,
			COALESCE(SUM(CASE WHEN b.status = 'completed' THEN 1 ELSE 0 END), 0) AS completed
		FROM bookings b
		JOIN sessions s ON s.id = b.session_id AND s.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		WHERE b.school_id = ?
		  AND b.status != 'cancelled'
		  AND s.starts_at >= ? AND s.starts_at < ?
		  AND UPPER(ct.code) LIKE 'CBT%'
	`
	var total, completed int
	if err := scope.Conn().QueryRowContext(ctx, q,
		string(scope.SchoolID()), w.fromISO(), w.toISO(),
	).Scan(&total, &completed); err != nil {
		return wrap("cbt completion", err)
	}
	out.CBTSample = total
	if total > 0 {
		out.CBTCompletionPct = float64(completed) / float64(total) * 100
	}
	return nil
}

// computeTestPassRates: pass rates for theory + practical external
// tests created in the window. Outcomes 'booked' and 'not_yet' are
// excluded — we only count tests with a decided result.
func computeTestPassRates(ctx context.Context, scope *tenant.Scope, w Window, out *FunnelStats) error {
	const q = `
		SELECT
			CASE
				WHEN UPPER(test_type) = 'THEORY' THEN 'theory'
				ELSE 'practical'
			END AS bucket,
			COUNT(*) AS attempts,
			COALESCE(SUM(CASE WHEN outcome = 'pass' THEN 1 ELSE 0 END), 0) AS passes
		FROM external_tests
		WHERE school_id = ?
		  AND outcome IN ('pass', 'fail')
		  AND created_at >= ? AND created_at < ?
		GROUP BY bucket
	`
	rows, err := scope.Conn().QueryContext(ctx, q,
		string(scope.SchoolID()), w.fromISO(), w.toISO())
	if err != nil {
		return wrap("test pass rates", err)
	}
	defer rows.Close()
	for rows.Next() {
		var bucket string
		var attempts, passes int
		if err := rows.Scan(&bucket, &attempts, &passes); err != nil {
			return wrap("scan pass row", err)
		}
		pct := 0.0
		if attempts > 0 {
			pct = float64(passes) / float64(attempts) * 100
		}
		switch bucket {
		case "theory":
			out.TheorySample = attempts
			out.TheoryPassPct = pct
		case "practical":
			out.PracticalSample = attempts
			out.PracticalPassPct = pct
		}
	}
	return rows.Err()
}

// computePerInstructorPassRates attributes each decided external test
// to the most-recent non-cancelled instructor the student had in the
// 90 days before the test. Documented attribution model — not exact;
// it's a "who was their last instructor before the test" heuristic.
func computePerInstructorPassRates(ctx context.Context, scope *tenant.Scope, w Window, out *FunnelStats) error {
	const q = `
		WITH attributed AS (
			SELECT
				et.id AS test_id,
				et.outcome,
				(
					SELECT s.instructor_id
					FROM bookings b
					JOIN sessions s ON s.id = b.session_id AND s.school_id = b.school_id
					WHERE b.school_id = et.school_id
					  AND b.student_id = et.student_id
					  AND b.status NOT IN ('cancelled', 'no_show')
					  AND s.starts_at <= et.created_at
					  AND s.starts_at >= datetime(et.created_at, '-90 days')
					ORDER BY s.starts_at DESC
					LIMIT 1
				) AS instructor_id
			FROM external_tests et
			WHERE et.school_id = ?
			  AND et.outcome IN ('pass', 'fail')
			  AND et.created_at >= ? AND et.created_at < ?
		)
		SELECT
			u.id,
			COALESCE(u.name, u.email, u.id),
			COUNT(a.test_id),
			COALESCE(SUM(CASE WHEN a.outcome = 'pass' THEN 1 ELSE 0 END), 0)
		FROM attributed a
		JOIN users u ON u.id = a.instructor_id
		WHERE a.instructor_id IS NOT NULL
		GROUP BY u.id
		ORDER BY COUNT(a.test_id) DESC, u.name ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q,
		string(scope.SchoolID()), w.fromISO(), w.toISO())
	if err != nil {
		return wrap("per-instructor pass rates", err)
	}
	defer rows.Close()
	for rows.Next() {
		var r InstructorPassRate
		if err := rows.Scan(&r.InstructorID, &r.Name, &r.Attempts, &r.Passes); err != nil {
			return wrap("scan instructor pass row", err)
		}
		if r.Attempts > 0 {
			r.PassPct = float64(r.Passes) / float64(r.Attempts) * 100
		}
		out.PerInstructorPassRate = append(out.PerInstructorPassRate, r)
	}
	return rows.Err()
}
