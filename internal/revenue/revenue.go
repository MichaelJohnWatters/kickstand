// Package revenue is read-only aggregation behind the admin Finance
// dashboard.
//
// All views derive from `charges` and `payments` (voided rows excluded).
// Time bucketing happens server-side so the client just renders bars.
// SQLite has limited date-math compared to Postgres — we substring the
// ISO timestamps for month buckets, which works because every column we
// query writes RFC3339 UTC.
package revenue

import (
	"context"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// MonthBucket is one month of revenue activity.
type MonthBucket struct {
	Month        string // YYYY-MM
	BilledPence  int64  // charges incurred in this month (voided excluded)
	CollectedPence int64 // payments received in this month
}

type MonthlyReport struct {
	Buckets []MonthBucket
	// Outstanding right now (sum of non-voided charges minus non-voided
	// payments). Snapshot, not a per-bucket figure.
	OutstandingPence int64
}

// Monthly returns the last `months` calendar months of activity (ending
// in the current month), oldest first. Empty buckets are filled with
// zeros so the chart axis is contiguous.
func Monthly(ctx context.Context, scope *tenant.Scope, months int) (*MonthlyReport, error) {
	if months <= 0 || months > 36 {
		months = 12
	}

	// Build the list of YYYY-MM keys we expect.
	now := time.Now().UTC()
	start := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC).
		AddDate(0, -(months - 1), 0)
	keys := make([]string, 0, months)
	keyIdx := make(map[string]int, months)
	for i := 0; i < months; i++ {
		k := start.AddDate(0, i, 0).Format("2006-01")
		keyIdx[k] = i
		keys = append(keys, k)
	}
	buckets := make([]MonthBucket, months)
	for i, k := range keys {
		buckets[i] = MonthBucket{Month: k}
	}

	// Billed (non-voided charges) — incurred_at is RFC3339, first 7 chars
	// are YYYY-MM.
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT substr(incurred_at, 1, 7) AS m, COALESCE(SUM(amount_pence), 0)
		FROM charges
		WHERE school_id = ? AND voided_at IS NULL
		  AND substr(incurred_at, 1, 7) >= ?
		GROUP BY m
	`, string(scope.SchoolID()), keys[0])
	if err != nil {
		return nil, fmt.Errorf("billed: %w", err)
	}
	for rows.Next() {
		var m string
		var sum int64
		if err := rows.Scan(&m, &sum); err != nil {
			rows.Close()
			return nil, err
		}
		if i, ok := keyIdx[m]; ok {
			buckets[i].BilledPence = sum
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Collected (non-voided payments).
	rows, err = scope.Conn().QueryContext(ctx, `
		SELECT substr(received_at, 1, 7) AS m, COALESCE(SUM(amount_pence), 0)
		FROM payments
		WHERE school_id = ? AND voided_at IS NULL
		  AND substr(received_at, 1, 7) >= ?
		GROUP BY m
	`, string(scope.SchoolID()), keys[0])
	if err != nil {
		return nil, fmt.Errorf("collected: %w", err)
	}
	for rows.Next() {
		var m string
		var sum int64
		if err := rows.Scan(&m, &sum); err != nil {
			rows.Close()
			return nil, err
		}
		if i, ok := keyIdx[m]; ok {
			buckets[i].CollectedPence = sum
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Snapshot outstanding (no date filter).
	var billedAll, paidAll int64
	if err := scope.Conn().QueryRowContext(ctx, `
		SELECT COALESCE(SUM(amount_pence), 0) FROM charges
		WHERE school_id = ? AND voided_at IS NULL
	`, string(scope.SchoolID())).Scan(&billedAll); err != nil {
		return nil, err
	}
	if err := scope.Conn().QueryRowContext(ctx, `
		SELECT COALESCE(SUM(amount_pence), 0) FROM payments
		WHERE school_id = ? AND voided_at IS NULL
	`, string(scope.SchoolID())).Scan(&paidAll); err != nil {
		return nil, err
	}

	return &MonthlyReport{
		Buckets:          buckets,
		OutstandingPence: billedAll - paidAll,
	}, nil
}

// AgeingBucket is one row in the 30/60/90+ outstanding ageing report.
type AgeingBucket struct {
	Label string // "0–30 days", "31–60 days", etc.
	Pence int64
}

// Ageing returns total outstanding (charges minus payments) bucketed
// by how long ago the underlying charge was incurred. Anchored to
// today; payments don't have an ageing concept of their own — they're
// applied LIFO conceptually but here we just net the totals per
// bucket. (For a clean payment-application algorithm we'd need a
// payment-allocation table; out of scope for the MVP.)
func Ageing(ctx context.Context, scope *tenant.Scope) ([]AgeingBucket, error) {
	now := time.Now().UTC()
	cut30 := now.AddDate(0, 0, -30).Format(time.RFC3339)
	cut60 := now.AddDate(0, 0, -60).Format(time.RFC3339)
	cut90 := now.AddDate(0, 0, -90).Format(time.RFC3339)

	// Outstanding per-student = sum non-voided charges − sum non-voided
	// payments. We do it at student-level to allocate payments against
	// the student's oldest charges first; then sum per bucket.
	const q = `
		WITH per_student AS (
			SELECT
			  u.id AS student_id,
			  COALESCE((SELECT SUM(amount_pence) FROM charges c
			            WHERE c.school_id = u.school_id
			              AND c.student_id = u.id
			              AND c.voided_at IS NULL), 0) AS billed,
			  COALESCE((SELECT SUM(amount_pence) FROM payments p
			            WHERE p.school_id = u.school_id
			              AND p.student_id = u.id
			              AND p.voided_at IS NULL), 0) AS paid
			FROM users u WHERE u.school_id = ? AND u.role = 'student'
		)
		SELECT student_id, billed - paid AS outstanding
		FROM per_student
		WHERE billed - paid > 0
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("per-student outstanding: %w", err)
	}
	defer rows.Close()

	buckets := []AgeingBucket{
		{Label: "0–30 days"},
		{Label: "31–60 days"},
		{Label: "61–90 days"},
		{Label: "90+ days"},
	}
	for rows.Next() {
		var studentID string
		var owed int64
		if err := rows.Scan(&studentID, &owed); err != nil {
			return nil, err
		}
		// Oldest non-voided charge for this student determines the bucket.
		// One round-trip per indebted student is fine for school-scale
		// data (50–500 active students).
		var oldest string
		if err := scope.Conn().QueryRowContext(ctx, `
			SELECT MIN(incurred_at) FROM charges
			WHERE school_id = ? AND student_id = ? AND voided_at IS NULL
		`, string(scope.SchoolID()), studentID).Scan(&oldest); err != nil {
			return nil, err
		}
		switch {
		case oldest == "":
			// Defensive: no charges but billed-paid > 0 means a credit was
			// recorded but the underlying charge was voided. Skip.
			continue
		case oldest >= cut30:
			buckets[0].Pence += owed
		case oldest >= cut60:
			buckets[1].Pence += owed
		case oldest >= cut90:
			buckets[2].Pence += owed
		default:
			buckets[3].Pence += owed
		}
	}
	return buckets, rows.Err()
}

// ByCourseBucket is one row of revenue by course type — useful to tell
// what's actually paying the bills.
type ByCourseBucket struct {
	CourseTypeID string
	Code         string
	Name         string
	BookingCount int
	BilledPence  int64
}

// ByCourse returns each course's contribution to revenue from charges
// linked to a booking (the auto-charge path). Manually-typed charges
// without a booking_id are excluded — they don't have a course they
// belong to.
func ByCourse(ctx context.Context, scope *tenant.Scope) ([]ByCourseBucket, error) {
	const q = `
		SELECT ct.id, ct.code, ct.name,
		       COUNT(DISTINCT c.booking_id) AS bookings,
		       COALESCE(SUM(c.amount_pence), 0) AS billed
		FROM course_types ct
		LEFT JOIN sessions s ON s.course_type_id = ct.id AND s.school_id = ct.school_id
		LEFT JOIN bookings b ON b.session_id = s.id AND b.school_id = s.school_id
		LEFT JOIN charges  c ON c.booking_id = b.id AND c.school_id = b.school_id
		                    AND c.voided_at IS NULL
		WHERE ct.school_id = ?
		GROUP BY ct.id
		ORDER BY billed DESC, ct.name ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("by-course: %w", err)
	}
	defer rows.Close()
	var out []ByCourseBucket
	for rows.Next() {
		var b ByCourseBucket
		if err := rows.Scan(&b.CourseTypeID, &b.Code, &b.Name, &b.BookingCount, &b.BilledPence); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}
