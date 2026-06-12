// Package calendar produces the admin master-calendar payload — all
// sessions in a date range with full context, plus non-blocking travel
// warnings between consecutive sessions when the same instructor moves
// between sites with an unrealistic gap.
//
// Per plan §5 ("Instructor travel between sites — assistive warning"):
//   - Warn-don't-block: matrix is a prompt for attention, not authority.
//   - Feasibility check: gap ≥ travel time + per-school buffer.
//   - Same matrix is reused for bike logistics — same predicate, different
//     consumer.
package calendar

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// SessionRow is one row in the calendar payload.
type SessionRow struct {
	SessionID          domain.SessionID
	CourseTypeID       domain.CourseTypeID
	CourseCode         string
	CourseName         string
	CourseAccentColour string
	NonTeaching        bool
	// Legacy single-instructor fields; populated from the primary
	// session_instructors row. Kept for ease of read; the full list
	// lives in Instructors below.
	InstructorID       domain.UserID
	InstructorName     string
	Instructors        []SessionInstructor
	LocationID         domain.LocationID
	LocationName       string
	StartsAt           time.Time
	EndsAt             time.Time
	Capacity           int
	ActiveBookings     int
	// Students is the list of names currently booked. Short enough to
	// inline in the calendar block (typical capacity 1–4); empty when
	// nobody's booked yet.
	Students           []SessionStudent
	Status             string
}

// SessionInstructor is one row of the assignment.
type SessionInstructor struct {
	ID        domain.UserID
	Name      string
	IsPrimary bool
}

// SessionStudent is one booking on the session, lightly denormalised
// for the calendar display. The booking id + assigned bike are
// included so the calendar's edit sheet can wire cancel / swap actions
// without a second round-trip to /sessions/{id}/detail.
type SessionStudent struct {
	ID           domain.UserID
	Name         string
	Status       string // 'booked' | 'needs_reassignment' | 'completed' | 'no_show'
	BookingID    domain.BookingID
	BikeID       domain.BikeID
	BikeNickname string
}

// TravelWarning surfaces a tight inter-session gap for one instructor.
type TravelWarning struct {
	InstructorID        domain.UserID
	InstructorName      string
	FromSessionID       domain.SessionID
	ToSessionID         domain.SessionID
	FromLocationID      domain.LocationID
	FromLocationName    string
	ToLocationID        domain.LocationID
	ToLocationName      string
	FromEndsAt          time.Time
	ToStartsAt          time.Time
	GapMinutes          int
	TravelMinutes       int
	BufferMinutes       int
	Message             string
}

// Query selects which sessions to include.
type Query struct {
	From         time.Time
	To           time.Time
	InstructorID domain.UserID       // optional
	LocationID   domain.LocationID   // optional
	CourseTypeID domain.CourseTypeID // optional
	// IncludeCancelled enables the master calendar's "Show cancelled"
	// toggle. Cancelled sessions get returned alongside scheduled
	// ones, and the per-session students list also includes cancelled
	// bookings (rendered faded + struck-through client-side). Off by
	// default — most callers want the lean view.
	IncludeCancelled bool
}

type Payload struct {
	Sessions []SessionRow
	Warnings []TravelWarning
}

// Build runs the query and computes travel warnings in one pass.
func Build(ctx context.Context, scope *tenant.Scope, q Query) (*Payload, error) {
	sessions, err := loadSessions(ctx, scope, q)
	if err != nil {
		return nil, err
	}

	// Load travel matrix + per-school buffer.
	bufferMin, err := loadBuffer(ctx, scope)
	if err != nil {
		return nil, err
	}
	matrix, err := loadMatrix(ctx, scope)
	if err != nil {
		return nil, err
	}

	warnings := computeTravelWarnings(sessions, matrix, bufferMin)
	return &Payload{Sessions: sessions, Warnings: warnings}, nil
}

func loadSessions(ctx context.Context, scope *tenant.Scope, q Query) ([]SessionRow, error) {
	query := `
		SELECT s.id, s.course_type_id, COALESCE(ct.code, ''), COALESCE(ct.name, ''),
		       COALESCE(ct.accent_colour, ''),
		       COALESCE(ct.non_teaching, 0),
		       COALESCE(s.instructor_id, ''), COALESCE(u.name, ''),
		       s.location_id, COALESCE(l.name, ''),
		       s.starts_at, s.ends_at, s.capacity, s.status,
		       (SELECT COUNT(*) FROM bookings b
		         WHERE b.school_id = s.school_id
		           AND b.session_id = s.id
		           AND b.status IN ('booked', 'needs_reassignment', 'completed', 'no_show')) AS active_bookings
		FROM sessions s
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN users u    ON u.id = s.instructor_id   AND u.school_id = s.school_id
		LEFT JOIN locations l ON l.id = s.location_id    AND l.school_id = s.school_id
		WHERE s.school_id = ?
		  AND s.starts_at >= ? AND s.starts_at < ?
	`
	if !q.IncludeCancelled {
		query += ` AND s.status <> 'cancelled'`
	}
	args := []any{string(scope.SchoolID()), q.From.Format(time.RFC3339), q.To.Format(time.RFC3339)}
	if q.InstructorID != "" {
		query += ` AND s.instructor_id = ?`
		args = append(args, string(q.InstructorID))
	}
	if q.LocationID != "" {
		query += ` AND s.location_id = ?`
		args = append(args, string(q.LocationID))
	}
	if q.CourseTypeID != "" {
		query += ` AND s.course_type_id = ?`
		args = append(args, string(q.CourseTypeID))
	}
	query += ` ORDER BY s.starts_at ASC, s.instructor_id ASC`

	rows, err := scope.Conn().QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionRow
	for rows.Next() {
		var (
			r              SessionRow
			startsStr, ends string
			nonTeachingInt int
		)
		if err := rows.Scan(
			&r.SessionID, &r.CourseTypeID, &r.CourseCode, &r.CourseName,
			&r.CourseAccentColour,
			&nonTeachingInt,
			&r.InstructorID, &r.InstructorName,
			&r.LocationID, &r.LocationName,
			&startsStr, &ends, &r.Capacity, &r.Status, &r.ActiveBookings,
		); err != nil {
			return nil, err
		}
		r.NonTeaching = nonTeachingInt == 1
		r.StartsAt, _ = time.Parse(time.RFC3339, startsStr)
		r.EndsAt, _ = time.Parse(time.RFC3339, ends)
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := attachInstructors(ctx, scope, out); err != nil {
		return nil, err
	}
	if err := attachStudents(ctx, scope, out, q.IncludeCancelled); err != nil {
		return nil, err
	}
	return out, nil
}

// attachInstructors fans-out one SELECT keyed by all the session
// IDs we just loaded, then distributes the rows back into each
// SessionRow.Instructors slice in-memory. Avoids N+1 for the calendar
// payload's typical 30–100 sessions.
func attachInstructors(ctx context.Context, scope *tenant.Scope, sessions []SessionRow) error {
	if len(sessions) == 0 {
		return nil
	}
	placeholders, args := buildInClause(sessions, string(scope.SchoolID()))
	q := `
		SELECT si.session_id, si.instructor_id, COALESCE(u.name, ''), si.is_primary
		FROM session_instructors si
		LEFT JOIN users u ON u.id = si.instructor_id AND u.school_id = si.school_id
		WHERE si.school_id = ? AND si.session_id IN (` + placeholders + `)
		ORDER BY si.is_primary DESC, si.assigned_at ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	bySession := map[string][]SessionInstructor{}
	for rows.Next() {
		var sid, iid, name string
		var isPrimary int
		if err := rows.Scan(&sid, &iid, &name, &isPrimary); err != nil {
			return err
		}
		bySession[sid] = append(bySession[sid], SessionInstructor{
			ID:        domain.UserID(iid),
			Name:      name,
			IsPrimary: isPrimary == 1,
		})
	}
	for i := range sessions {
		sessions[i].Instructors = bySession[string(sessions[i].SessionID)]
	}
	return rows.Err()
}

// attachStudents pulls every booked / needs-reassignment student
// across the same session set. Each session typically has ≤ 4
// students so the slice stays cheap on the wire.
func attachStudents(ctx context.Context, scope *tenant.Scope, sessions []SessionRow, includeCancelled bool) error {
	if len(sessions) == 0 {
		return nil
	}
	placeholders, args := buildInClause(sessions, string(scope.SchoolID()))
	// Cancelled bookings are excluded by default — the master
	// calendar's "Show cancelled" toggle includes them when enabled
	// (drives the includeCancelled flag on the Query). activeBookings
	// (the capacity counter) excludes cancelled rows either way so
	// they don't double-count.
	statuses := "'booked', 'needs_reassignment', 'completed', 'no_show'"
	if includeCancelled {
		statuses += ", 'cancelled'"
	}
	q := `
		SELECT b.session_id, b.id, b.student_id, COALESCE(u.name, ''), b.status,
		       COALESCE(b.bike_id, ''), COALESCE(bk.nickname, '')
		FROM bookings b
		LEFT JOIN users u ON u.id = b.student_id AND u.school_id = b.school_id
		LEFT JOIN bikes bk ON bk.id = b.bike_id AND bk.school_id = b.school_id
		WHERE b.school_id = ? AND b.session_id IN (` + placeholders + `)
		  AND b.status IN (` + statuses + `)
		ORDER BY u.name ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	bySession := map[string][]SessionStudent{}
	for rows.Next() {
		var sid, bookingID, stuID, name, status, bikeID, bikeNick string
		if err := rows.Scan(&sid, &bookingID, &stuID, &name, &status,
			&bikeID, &bikeNick); err != nil {
			return err
		}
		bySession[sid] = append(bySession[sid], SessionStudent{
			ID:           domain.UserID(stuID),
			Name:         name,
			Status:       status,
			BookingID:    domain.BookingID(bookingID),
			BikeID:       domain.BikeID(bikeID),
			BikeNickname: bikeNick,
		})
	}
	for i := range sessions {
		sessions[i].Students = bySession[string(sessions[i].SessionID)]
	}
	return rows.Err()
}

// buildInClause emits "?, ?, ?, ..." for the SELECT placeholder list
// alongside the args slice (first arg is school_id, then the session
// IDs). Keeps the two attach* helpers boilerplate-free.
func buildInClause(sessions []SessionRow, schoolID string) (string, []any) {
	placeholders := ""
	args := make([]any, 0, len(sessions)+1)
	args = append(args, schoolID)
	for i, s := range sessions {
		if i > 0 {
			placeholders += ", "
		}
		placeholders += "?"
		args = append(args, string(s.SessionID))
	}
	return placeholders, args
}

func loadBuffer(ctx context.Context, scope *tenant.Scope) (int, error) {
	var n int
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT travel_buffer_minutes FROM schools WHERE id = ?`,
		string(scope.SchoolID()),
	).Scan(&n)
	return n, err
}

type travelKey struct {
	from domain.LocationID
	to   domain.LocationID
}

func loadMatrix(ctx context.Context, scope *tenant.Scope) (map[travelKey]int, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT from_location_id, to_location_id, minutes FROM travel_times WHERE school_id = ?
	`, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[travelKey]int{}
	for rows.Next() {
		var (
			f, t domain.LocationID
			m    int
		)
		if err := rows.Scan(&f, &t, &m); err != nil {
			return nil, err
		}
		out[travelKey{f, t}] = m
	}
	return out, rows.Err()
}

// computeTravelWarnings walks the sessions list per instructor, in order,
// and emits a warning whenever the gap between consecutive sessions at
// different locations is less than the recorded travel time plus buffer.
//
// If the matrix doesn't have an entry for a pair, we silently skip — the
// system can't claim "tight travel" without data.
func computeTravelWarnings(sessions []SessionRow, matrix map[travelKey]int, bufferMin int) []TravelWarning {
	// Bucket by instructor, then sort each bucket by start time.
	byInstr := map[domain.UserID][]SessionRow{}
	for _, s := range sessions {
		byInstr[s.InstructorID] = append(byInstr[s.InstructorID], s)
	}

	var out []TravelWarning
	for _, group := range byInstr {
		sort.Slice(group, func(i, j int) bool {
			return group[i].StartsAt.Before(group[j].StartsAt)
		})
		for i := 1; i < len(group); i++ {
			prev := group[i-1]
			curr := group[i]
			if prev.LocationID == curr.LocationID {
				continue // same site, no travel
			}
			travel, ok := matrix[travelKey{prev.LocationID, curr.LocationID}]
			if !ok {
				continue // no data → can't reason
			}
			gap := int(curr.StartsAt.Sub(prev.EndsAt).Minutes())
			needed := travel + bufferMin
			if gap < needed {
				out = append(out, TravelWarning{
					InstructorID:     prev.InstructorID,
					InstructorName:   prev.InstructorName,
					FromSessionID:    prev.SessionID,
					ToSessionID:      curr.SessionID,
					FromLocationID:   prev.LocationID,
					FromLocationName: prev.LocationName,
					ToLocationID:     curr.LocationID,
					ToLocationName:   curr.LocationName,
					FromEndsAt:       prev.EndsAt,
					ToStartsAt:       curr.StartsAt,
					GapMinutes:       gap,
					TravelMinutes:    travel,
					BufferMinutes:    bufferMin,
					Message: fmt.Sprintf("Tight: %d min between %s→%s (drive usually ~%d min + %d min buffer).",
						gap, prev.LocationName, curr.LocationName, travel, bufferMin),
				})
			}
		}
	}
	// Deterministic ordering: by warning's ToStartsAt then instructor.
	sort.Slice(out, func(i, j int) bool {
		if out[i].ToStartsAt.Equal(out[j].ToStartsAt) {
			return out[i].InstructorID < out[j].InstructorID
		}
		return out[i].ToStartsAt.Before(out[j].ToStartsAt)
	})
	return out
}
