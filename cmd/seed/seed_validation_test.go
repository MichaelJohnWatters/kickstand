package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/michaeljohnwatters/kickstand/internal/db"
)

// TestSeedInvariants runs the demo seed against a tmp DB and asserts
// the resulting state is internally consistent with the engine's rules
// — every row could plausibly have been reached through legitimate
// admin / student API calls.
//
// The test is the safety net for the eventual rewrite of the seed to
// drive the engine directly instead of raw INSERTs. Until that
// rewrite lands, this test catches the worst class of bug: seed data
// that contradicts an invariant the live engine enforces.
//
// Each sub-test runs a single SQL query that returns *violation* rows
// — zero rows means the invariant holds.
func TestSeedInvariants(t *testing.T) {
	// Isolate filestore output (the seed's local-disk fallback writes
	// receipt blobs to ./uploads) and keep the DB file in a temp dir.
	dir := t.TempDir()
	prev, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(prev) })

	dsn := filepath.Join(dir, "seed_test.db")
	if err := run(dsn); err != nil {
		t.Fatalf("seed run: %v", err)
	}
	d, err := db.Open(dsn)
	if err != nil {
		t.Fatalf("open seeded db: %v", err)
	}
	defer d.Close()

	ctx := context.Background()
	for _, c := range invariantChecks {
		t.Run(c.name, func(t *testing.T) {
			violations, err := runViolationQuery(ctx, d, c.query)
			if err != nil {
				t.Fatalf("query: %v", err)
			}
			if len(violations) > 0 {
				t.Errorf("%s\n  %d violation(s):\n    - %s",
					c.detail,
					len(violations),
					strings.Join(violations, "\n    - "))
			}
		})
	}
}

type invariantCheck struct {
	name   string
	detail string // human-readable explanation printed on failure
	query  string // returns one row per violation; columns are diagnostic
}

var invariantChecks = []invariantCheck{
	{
		name: "shared_bike_within_session",
		detail: "Two non-cancelled bookings on the same session should never share a bike — " +
			"the engine wouldn't let the second student pick a bike the first one holds.",
		query: `
			SELECT a.session_id, a.bike_id,
			       a.id AS booking_a, a.status AS status_a,
			       b.id AS booking_b, b.status AS status_b
			FROM bookings a
			JOIN bookings b
			  ON b.school_id = a.school_id
			 AND b.session_id = a.session_id
			 AND b.bike_id = a.bike_id
			 AND b.id > a.id
			WHERE a.status != 'cancelled' AND b.status != 'cancelled'
			  AND a.bike_id IS NOT NULL AND a.bike_id != ''
		`,
	},
	{
		name: "overlapping_bike_across_sessions",
		detail: "An active booking (booked / needs_reassignment) should not share a bike with " +
			"another active booking whose session overlaps in time — that's the engine's core conflict guard.",
		query: `
			SELECT b1.id AS booking_1, b2.id AS booking_2, b1.bike_id,
			       s1.id AS session_1, s2.id AS session_2,
			       s1.starts_at AS s1_starts, s1.ends_at AS s1_ends,
			       s2.starts_at AS s2_starts, s2.ends_at AS s2_ends
			FROM bookings b1
			JOIN bookings b2
			  ON b2.school_id = b1.school_id
			 AND b2.bike_id = b1.bike_id
			 AND b2.id > b1.id
			JOIN sessions s1 ON s1.id = b1.session_id AND s1.school_id = b1.school_id
			JOIN sessions s2 ON s2.id = b2.session_id AND s2.school_id = b2.school_id
			WHERE b1.status IN ('booked', 'needs_reassignment')
			  AND b2.status IN ('booked', 'needs_reassignment')
			  AND b1.bike_id IS NOT NULL AND b1.bike_id != ''
			  AND s1.id != s2.id
			  AND s1.starts_at < s2.ends_at
			  AND s2.starts_at < s1.ends_at
		`,
	},
	{
		name: "session_over_capacity",
		detail: "A session's held bookings (booked + needs_reassignment + completed + no_show) should " +
			"never exceed its capacity.",
		query: `
			SELECT s.id, s.capacity, COUNT(b.id) AS held
			FROM sessions s
			JOIN bookings b
			  ON b.session_id = s.id AND b.school_id = s.school_id
			WHERE b.status IN ('booked', 'needs_reassignment', 'completed', 'no_show')
			GROUP BY s.id, s.capacity
			HAVING held > s.capacity
		`,
	},
	{
		name: "bike_category_mismatch",
		detail: "Each booking's bike must match the session's required bike category.",
		query: `
			SELECT bk.id AS booking, bk.bike_id, bi.category AS bike_cat,
			       ct.required_bike_category AS need_cat, s.id AS session_id
			FROM bookings bk
			JOIN sessions s ON s.id = bk.session_id AND s.school_id = bk.school_id
			JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
			JOIN bikes bi ON bi.id = bk.bike_id AND bi.school_id = bk.school_id
			WHERE bk.bike_id IS NOT NULL AND bk.bike_id != ''
			  AND ct.required_bike_category != ''
			  AND bi.category != ct.required_bike_category
		`,
	},
	{
		name: "needs_reassignment_without_disruption",
		detail: "Every needs_reassignment booking should have a pending disruption_affected_bookings " +
			"row — that's the only legitimate way the engine sets that status.",
		query: `
			SELECT b.id, b.bike_id, b.session_id
			FROM bookings b
			WHERE b.status = 'needs_reassignment'
			  AND NOT EXISTS (
			    SELECT 1 FROM disruption_affected_bookings dab
			    WHERE dab.school_id = b.school_id
			      AND dab.booking_id = b.id
			      AND dab.resolution = 'pending'
			  )
		`,
	},
	{
		name: "swapped_disruption_bike_mismatch",
		detail: "A disruption row marked 'swapped' must point at the bike the booking now holds.",
		query: `
			SELECT dab.disruption_id, dab.booking_id,
			       dab.new_bike_id AS swapped_to, b.bike_id AS booking_has
			FROM disruption_affected_bookings dab
			JOIN bookings b
			  ON b.id = dab.booking_id AND b.school_id = dab.school_id
			WHERE dab.resolution = 'swapped'
			  AND (dab.new_bike_id IS NULL
			       OR dab.new_bike_id = ''
			       OR dab.new_bike_id != b.bike_id)
		`,
	},
	{
		name: "tenant_scope_session_vs_booking",
		detail: "Every booking's school_id must match its session's school_id (multi-tenant invariant).",
		query: `
			SELECT b.id, b.school_id AS booking_school, s.school_id AS session_school
			FROM bookings b
			JOIN sessions s ON s.id = b.session_id
			WHERE b.school_id != s.school_id
		`,
	},
	{
		name: "tenant_scope_user_vs_booking",
		detail: "Every booking's school_id must match its student's school_id.",
		query: `
			SELECT b.id, b.school_id AS booking_school, u.school_id AS student_school
			FROM bookings b
			JOIN users u ON u.id = b.student_id
			WHERE b.school_id != u.school_id
		`,
	},
	{
		name: "tenant_scope_bike_vs_booking",
		detail: "Every booking's school_id must match its bike's school_id (when a bike is assigned).",
		query: `
			SELECT b.id, b.school_id AS booking_school, bi.school_id AS bike_school
			FROM bookings b
			JOIN bikes bi ON bi.id = b.bike_id
			WHERE b.bike_id IS NOT NULL AND b.bike_id != ''
			  AND b.school_id != bi.school_id
		`,
	},
	{
		name: "cancelled_booking_missing_audit_fields",
		detail: "A cancelled booking should carry both cancelled_by and cancelled_at so the audit log + UI render correctly.",
		query: `
			SELECT id, status, cancelled_by, cancelled_at
			FROM bookings
			WHERE status = 'cancelled'
			  AND (cancelled_by IS NULL OR cancelled_by = ''
			       OR cancelled_at IS NULL OR cancelled_at = '')
		`,
	},

	// ---------- Profiles ↔ users ----------

	{
		name:   "instructor_profile_not_instructor",
		detail: "instructor_profiles.user_id must point at a user whose role is 'instructor'.",
		query: `
			SELECT ip.user_id, u.role
			FROM instructor_profiles ip
			JOIN users u ON u.id = ip.user_id
			WHERE u.role != 'instructor'
		`,
	},
	{
		name:   "instructor_profile_school_mismatch",
		detail: "instructor_profiles.school_id must equal the user's school_id.",
		query: `
			SELECT ip.user_id, ip.school_id AS profile_school, u.school_id AS user_school
			FROM instructor_profiles ip
			JOIN users u ON u.id = ip.user_id
			WHERE ip.school_id != u.school_id
		`,
	},
	{
		name:   "instructor_profile_home_location_cross_school",
		detail: "instructor_profiles.home_location_id must belong to the same school as the profile.",
		query: `
			SELECT ip.user_id, ip.home_location_id, l.school_id AS loc_school, ip.school_id AS profile_school
			FROM instructor_profiles ip
			JOIN locations l ON l.id = ip.home_location_id
			WHERE ip.home_location_id IS NOT NULL
			  AND ip.home_location_id != ''
			  AND l.school_id != ip.school_id
		`,
	},
	{
		name:   "student_profile_not_student",
		detail: "student_profiles.user_id must point at a user whose role is 'student'.",
		query: `
			SELECT sp.user_id, u.role
			FROM student_profiles sp
			JOIN users u ON u.id = sp.user_id
			WHERE u.role != 'student'
		`,
	},
	{
		name:   "student_profile_school_mismatch",
		detail: "student_profiles.school_id must equal the user's school_id.",
		query: `
			SELECT sp.user_id, sp.school_id AS profile_school, u.school_id AS user_school
			FROM student_profiles sp
			JOIN users u ON u.id = sp.user_id
			WHERE sp.school_id != u.school_id
		`,
	},

	// ---------- Accreditations + qualifications ----------

	{
		name:   "accreditation_user_not_instructor",
		detail: "Accreditation rows must be for users whose role is 'instructor'.",
		query: `
			SELECT ia.instructor_id, u.role
			FROM instructor_accreditations ia
			JOIN users u ON u.id = ia.instructor_id
			WHERE u.role != 'instructor'
		`,
	},
	{
		name:   "accreditation_cross_school",
		detail: "Accreditation rows must share a school with both the instructor and the course type.",
		query: `
			SELECT ia.instructor_id, ia.course_type_id, ia.school_id,
			       u.school_id AS user_school, ct.school_id AS course_school
			FROM instructor_accreditations ia
			JOIN users u ON u.id = ia.instructor_id
			JOIN course_types ct ON ct.id = ia.course_type_id
			WHERE ia.school_id != u.school_id OR ia.school_id != ct.school_id
		`,
	},

	// ---------- Resources ----------

	{
		name:   "travel_time_cross_school_location",
		detail: "travel_times must reference locations belonging to the row's school.",
		query: `
			SELECT tt.school_id, tt.from_location_id, tt.to_location_id,
			       lf.school_id AS from_school, lt.school_id AS to_school
			FROM travel_times tt
			JOIN locations lf ON lf.id = tt.from_location_id
			JOIN locations lt ON lt.id = tt.to_location_id
			WHERE lf.school_id != tt.school_id OR lt.school_id != tt.school_id
		`,
	},
	{
		name:   "bike_home_location_cross_school",
		detail: "bikes.home_location_id and current_location_id must belong to the bike's school.",
		query: `
			SELECT b.id, b.school_id, b.home_location_id, b.current_location_id,
			       lh.school_id AS home_school, lc.school_id AS current_school
			FROM bikes b
			JOIN locations lh ON lh.id = b.home_location_id
			JOIN locations lc ON lc.id = b.current_location_id
			WHERE lh.school_id != b.school_id OR lc.school_id != b.school_id
		`,
	},
	{
		name:   "bike_unavailability_window_inverted",
		detail: "bike_unavailability.starts_at must be strictly before ends_at.",
		query: `
			SELECT id, bike_id, starts_at, ends_at
			FROM bike_unavailability
			WHERE starts_at >= ends_at
		`,
	},
	{
		name:   "bike_unavailability_cross_school",
		detail: "bike_unavailability must share a school with the bike and the creator user.",
		query: `
			SELECT bu.id, bu.school_id, b.school_id AS bike_school, u.school_id AS creator_school
			FROM bike_unavailability bu
			JOIN bikes b ON b.id = bu.bike_id
			JOIN users u ON u.id = bu.created_by
			WHERE b.school_id != bu.school_id OR u.school_id != bu.school_id
		`,
	},

	// ---------- Sessions ----------

	{
		name:   "session_window_inverted",
		detail: "sessions.starts_at must be strictly before ends_at.",
		query: `
			SELECT id, starts_at, ends_at
			FROM sessions
			WHERE starts_at >= ends_at
		`,
	},
	{
		name:   "session_cross_school_dependencies",
		detail: "A session's course_type, location and (legacy) instructor must all be in the same school.",
		query: `
			SELECT s.id, s.school_id, s.course_type_id, s.location_id, s.instructor_id,
			       ct.school_id AS ct_school, l.school_id AS loc_school,
			       u.school_id AS instr_school
			FROM sessions s
			JOIN course_types ct ON ct.id = s.course_type_id
			JOIN locations l ON l.id = s.location_id
			LEFT JOIN users u ON u.id = s.instructor_id
			WHERE ct.school_id != s.school_id
			   OR l.school_id != s.school_id
			   OR (u.id IS NOT NULL AND u.school_id != s.school_id)
		`,
	},
	{
		name:   "session_non_positive_capacity",
		detail: "sessions.capacity must be > 0 — a session with no room can't take any booking.",
		query: `
			SELECT id, capacity FROM sessions WHERE capacity <= 0
		`,
	},
	{
		name:   "session_instructors_not_instructor",
		detail: "session_instructors.instructor_id must point at a user whose role is 'instructor'.",
		query: `
			SELECT si.session_id, si.instructor_id, u.role
			FROM session_instructors si
			JOIN users u ON u.id = si.instructor_id
			WHERE u.role != 'instructor'
		`,
	},
	{
		name:   "session_instructors_cross_school",
		detail: "session_instructors rows must share a school with both session and instructor.",
		query: `
			SELECT si.session_id, si.instructor_id, si.school_id,
			       s.school_id AS sess_school, u.school_id AS instr_school
			FROM session_instructors si
			JOIN sessions s ON s.id = si.session_id
			JOIN users u ON u.id = si.instructor_id
			WHERE s.school_id != si.school_id OR u.school_id != si.school_id
		`,
	},
	{
		name: "session_instructor_missing_accreditation",
		detail: "Every instructor assigned to a session should be accredited for the session's course type — " +
			"the engine refuses to assign an un-accredited instructor.",
		query: `
			SELECT si.session_id, si.instructor_id, s.course_type_id
			FROM session_instructors si
			JOIN sessions s ON s.id = si.session_id
			WHERE NOT EXISTS (
			  SELECT 1 FROM instructor_accreditations ia
			  WHERE ia.school_id = si.school_id
			    AND ia.instructor_id = si.instructor_id
			    AND ia.course_type_id = s.course_type_id
			)
		`,
	},
	{
		name: "instructor_overlapping_sessions",
		detail: "An instructor must not be assigned to two scheduled sessions whose time windows overlap " +
			"— it's a calendar impossibility the engine guards against.",
		query: `
			SELECT si1.instructor_id, si1.session_id AS sess_a, si2.session_id AS sess_b,
			       s1.starts_at AS a_starts, s1.ends_at AS a_ends,
			       s2.starts_at AS b_starts, s2.ends_at AS b_ends
			FROM session_instructors si1
			JOIN session_instructors si2
			  ON si2.school_id = si1.school_id
			 AND si2.instructor_id = si1.instructor_id
			 AND si2.session_id > si1.session_id
			JOIN sessions s1 ON s1.id = si1.session_id
			JOIN sessions s2 ON s2.id = si2.session_id
			WHERE s1.status = 'scheduled' AND s2.status = 'scheduled'
			  AND s1.starts_at < s2.ends_at
			  AND s2.starts_at < s1.ends_at
		`,
	},

	// ---------- Course content ----------

	{
		name:   "competency_cross_school",
		detail: "competencies.course_type_id must belong to the row's school.",
		query: `
			SELECT c.id, c.school_id, ct.school_id AS ct_school
			FROM competencies c
			JOIN course_types ct ON ct.id = c.course_type_id
			WHERE ct.school_id != c.school_id
		`,
	},
	{
		name:   "course_prerequisite_cross_school",
		detail: "course_prerequisites.course_type_id must belong to the row's school.",
		query: `
			SELECT cp.course_type_id, cp.prereq_kind, cp.school_id, ct.school_id AS ct_school
			FROM course_prerequisites cp
			JOIN course_types ct ON ct.id = cp.course_type_id
			WHERE ct.school_id != cp.school_id
		`,
	},

	// ---------- Progress + disruption resolution ----------

	{
		name: "progress_competency_wrong_course",
		detail: "A progress_record's competency must belong to the same course type as the booked session — " +
			"otherwise we're recording an assessment that never could have happened.",
		query: `
			SELECT pr.id, pr.competency_id, c.course_type_id AS comp_course,
			       s.course_type_id AS sess_course
			FROM progress_records pr
			JOIN bookings b ON b.id = pr.booking_id
			JOIN sessions s ON s.id = b.session_id
			JOIN competencies c ON c.id = pr.competency_id
			WHERE c.course_type_id != s.course_type_id
		`,
	},
	{
		name:   "progress_student_mismatch",
		detail: "progress_records.student_id must equal the booking's student_id.",
		query: `
			SELECT pr.id, pr.student_id AS prog_student, b.student_id AS book_student
			FROM progress_records pr
			JOIN bookings b ON b.id = pr.booking_id
			WHERE pr.student_id != b.student_id
		`,
	},
	{
		name:   "progress_recorder_not_instructor",
		detail: "progress_records.recorded_by must be a user with role 'instructor'.",
		query: `
			SELECT pr.id, pr.recorded_by, u.role
			FROM progress_records pr
			JOIN users u ON u.id = pr.recorded_by
			WHERE u.role NOT IN ('instructor','admin','owner')
		`,
	},
	{
		name:   "disruption_cross_school",
		detail: "disruptions.bike_id and created_by must share the disruption's school.",
		query: `
			SELECT d.id, d.school_id, b.school_id AS bike_school, u.school_id AS creator_school
			FROM disruptions d
			JOIN bikes b ON b.id = d.bike_id
			JOIN users u ON u.id = d.created_by
			WHERE b.school_id != d.school_id OR u.school_id != d.school_id
		`,
	},
	{
		name:   "disruption_cancelled_resolution_not_cancelled",
		detail: "A disruption resolution of 'cancelled' or 'cancel_with_approval' implies the booking is cancelled.",
		query: `
			SELECT dab.disruption_id, dab.booking_id, dab.resolution, b.status
			FROM disruption_affected_bookings dab
			JOIN bookings b ON b.id = dab.booking_id
			WHERE dab.resolution IN ('cancelled', 'cancel_with_approval')
			  AND b.status != 'cancelled'
		`,
	},

	// ---------- Ledger ----------

	{
		name:   "charge_student_not_student",
		detail: "charges.student_id must point at a user with role 'student'.",
		query: `
			SELECT c.id, c.student_id, u.role
			FROM charges c
			JOIN users u ON u.id = c.student_id
			WHERE u.role != 'student'
		`,
	},
	{
		name:   "charge_zero_amount",
		detail: "A live (non-voided) charge should be a non-zero amount.",
		query: `
			SELECT id, amount_pence FROM charges
			WHERE voided_at IS NULL AND amount_pence = 0
		`,
	},
	{
		name:   "payment_student_not_student",
		detail: "payments.student_id must point at a user with role 'student'.",
		query: `
			SELECT p.id, p.student_id, u.role
			FROM payments p
			JOIN users u ON u.id = p.student_id
			WHERE u.role != 'student'
		`,
	},
	{
		name:   "payment_non_positive",
		detail: "A live (non-voided) payment should be a positive amount.",
		query: `
			SELECT id, amount_pence FROM payments
			WHERE voided_at IS NULL AND amount_pence <= 0
		`,
	},

	// ---------- Incidents + notes ----------

	{
		name:   "incident_cross_school",
		detail: "incidents.bike_id, student_id and booking_id must share the incident's school when set.",
		query: `
			SELECT i.id, i.school_id, b.school_id AS bike_school,
			       u.school_id AS student_school, bk.school_id AS booking_school
			FROM incidents i
			LEFT JOIN bikes b ON b.id = i.bike_id
			LEFT JOIN users u ON u.id = i.student_id
			LEFT JOIN bookings bk ON bk.id = i.booking_id
			WHERE (b.id IS NOT NULL AND b.school_id != i.school_id)
			   OR (u.id IS NOT NULL AND u.school_id != i.school_id)
			   OR (bk.id IS NOT NULL AND bk.school_id != i.school_id)
		`,
	},
	{
		name:   "student_note_about_non_student",
		detail: "student_notes.student_id must point at a user with role 'student'.",
		query: `
			SELECT sn.id, sn.student_id, u.role
			FROM student_notes sn
			JOIN users u ON u.id = sn.student_id
			WHERE u.role != 'student'
		`,
	},

	// ---------- Expenses ----------

	{
		name:   "expense_instructor_not_instructor",
		detail: "expenses.instructor_id must point at a user with role 'instructor'.",
		query: `
			SELECT e.id, e.instructor_id, u.role
			FROM expenses e
			JOIN users u ON u.id = e.instructor_id
			WHERE u.role != 'instructor'
		`,
	},
	{
		name:   "expense_cross_school",
		detail: "An expense and its instructor must share a school.",
		query: `
			SELECT e.id, e.school_id, u.school_id AS instr_school
			FROM expenses e
			JOIN users u ON u.id = e.instructor_id
			WHERE e.school_id != u.school_id
		`,
	},
	{
		name:   "bike_expense_cross_school",
		detail: "A bike_expense must share a school with the bike it's attached to.",
		query: `
			SELECT be.id, be.school_id, b.school_id AS bike_school
			FROM bike_expenses be
			JOIN bikes b ON b.id = be.bike_id
			WHERE be.school_id != b.school_id
		`,
	},
}

func runViolationQuery(ctx context.Context, d *sql.DB, q string) ([]string, error) {
	rows, err := d.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		parts := make([]string, len(cols))
		for i, c := range cols {
			parts[i] = fmt.Sprintf("%s=%v", c, vals[i])
		}
		out = append(out, strings.Join(parts, " "))
	}
	return out, rows.Err()
}
