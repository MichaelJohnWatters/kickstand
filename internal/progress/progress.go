// Package progress handles the instructor-app session detail flow:
// attendance, competency assessment, per-booking notes, and the
// student-progress rollup the student app shows.
//
// Per plan §3 & §10 (instructor app):
//   - Attendance: instructor marks Present (= completed) or No-show.
//   - Assess → competency capture per student per booking.
//   - Test days (non_teaching) skip competency capture entirely — they
//     still reserve bike/instructor and charge, but there's no assessment.
//
// Permissions live in the HTTP layer. Engine functions just take a
// recordedBy UserID and trust the caller has vetted who can assess what.
// A helper IsInstructorForBooking is provided so the HTTP layer can
// ask "is this caller the instructor on this session?" without
// reimplementing the join.
package progress

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

var (
	ErrBookingNotFound        = errors.New("progress: booking not found in this school")
	ErrCompetencyNotFound     = errors.New("progress: competency not found in this school")
	ErrCompetencyWrongCourse  = errors.New("progress: competency belongs to a different course type")
	ErrBookingNotInProgress   = errors.New("progress: booking is not in a state where attendance can be marked")
	ErrInvalidAttendance      = errors.New("progress: attendance status must be 'completed' or 'no_show'")
	ErrInvalidStatus          = errors.New("progress: assessment status invalid")
	ErrNonTeachingSession     = errors.New("progress: this is a test-day session — no competency assessment")
	ErrSessionNotFound        = errors.New("progress: session not found in this school")
	ErrStudentNotFound        = errors.New("progress: student not found in this school")
)

// Valid competency statuses (mirrors the CHECK constraint on progress_records).
const (
	StatusNotAssessed = "not_assessed"
	StatusDeveloping  = "developing"
	StatusCompetent   = "competent"
	StatusNeedsWork   = "needs_work"
)

func validStatus(s string) bool {
	switch s {
	case StatusNotAssessed, StatusDeveloping, StatusCompetent, StatusNeedsWork:
		return true
	}
	return false
}

// IsInstructorForBooking returns true if the given user is the instructor
// on the session the booking belongs to. Used by the HTTP layer to gate
// instructor-only operations to their own sessions.
func IsInstructorForBooking(ctx context.Context, scope *tenant.Scope, bookingID domain.BookingID, userID domain.UserID) (bool, error) {
	const q = `
		SELECT s.instructor_id
		FROM bookings b
		JOIN sessions s ON s.id = b.session_id AND s.school_id = b.school_id
		WHERE b.id = ? AND b.school_id = ?
	`
	var instructorID domain.UserID
	err := scope.Conn().QueryRowContext(ctx, q, string(bookingID), string(scope.SchoolID())).Scan(&instructorID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrBookingNotFound
	}
	if err != nil {
		return false, err
	}
	return instructorID == userID, nil
}

// ----- Attendance -----

type MarkAttendanceRequest struct {
	BookingID domain.BookingID
	Status    domain.BookingStatus // 'completed' or 'no_show'
}

// MarkAttendance transitions a 'booked' or 'needs_reassignment' booking to
// 'completed' or 'no_show'. The session might be mid-disruption (a
// needs_reassignment row), but the instructor can still record that the
// student showed up / didn't.
func MarkAttendance(ctx context.Context, scope *tenant.Scope, req MarkAttendanceRequest) error {
	if req.Status != domain.BookingCompleted && req.Status != domain.BookingNoShow {
		return ErrInvalidAttendance
	}
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE bookings SET status = ?
		WHERE id = ? AND school_id = ?
		  AND status IN ('booked', 'needs_reassignment')
	`, string(req.Status), string(req.BookingID), string(scope.SchoolID()))
	if err != nil {
		return fmt.Errorf("mark attendance: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return checkBookingExists(ctx, scope, req.BookingID, ErrBookingNotInProgress)
	}
	return nil
}

func checkBookingExists(ctx context.Context, scope *tenant.Scope, id domain.BookingID, ifWrongState error) error {
	var n int
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT 1 FROM bookings WHERE id = ? AND school_id = ?`,
		string(id), string(scope.SchoolID()),
	).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrBookingNotFound
	}
	if err != nil {
		return err
	}
	return ifWrongState
}

// ----- Booking notes -----

type SetBookingNotesRequest struct {
	BookingID domain.BookingID
	Notes     string
}

func SetBookingNotes(ctx context.Context, scope *tenant.Scope, req SetBookingNotesRequest) error {
	res, err := scope.Conn().ExecContext(ctx,
		`UPDATE bookings SET notes = ? WHERE id = ? AND school_id = ?`,
		req.Notes, string(req.BookingID), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrBookingNotFound
	}
	return nil
}

// ----- Competency assessment -----

type AssessCompetencyRequest struct {
	BookingID    domain.BookingID
	CompetencyID domain.CompetencyID
	Status       string
	RecordedBy   domain.UserID
}

type ProgressRecord struct {
	ID           domain.ProgressID
	BookingID    domain.BookingID
	StudentID    domain.UserID
	CompetencyID domain.CompetencyID
	Status       string
	RecordedAt   time.Time
	RecordedBy   domain.UserID
}

// AssessCompetency upserts a per-booking-per-competency record. Refuses if
// the session's course type is non_teaching (test day).
//
// The competency must belong to the course type of the booking's session —
// the instructor can't accidentally assess "U-turn" against a CBT 600 if
// "U-turn" is only on CBT 125.
func AssessCompetency(ctx context.Context, scope *tenant.Scope, req AssessCompetencyRequest) (*ProgressRecord, error) {
	if !validStatus(req.Status) {
		return nil, ErrInvalidStatus
	}

	// Load booking + course type info + competency in one query to validate
	// alignment.
	const ctxQ = `
		SELECT b.student_id, s.course_type_id, COALESCE(ct.non_teaching, 0),
		       c.course_type_id
		FROM bookings b
		JOIN sessions s     ON s.id = b.session_id AND s.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN competencies c ON c.id = ? AND c.school_id = b.school_id
		WHERE b.id = ? AND b.school_id = ?
	`
	var (
		studentID            domain.UserID
		bookingCourse        domain.CourseTypeID
		nonTeachingInt       int
		competencyCourseNull sql.NullString
	)
	err := scope.Conn().QueryRowContext(ctx, ctxQ,
		string(req.CompetencyID), string(req.BookingID), string(scope.SchoolID()),
	).Scan(&studentID, &bookingCourse, &nonTeachingInt, &competencyCourseNull)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrBookingNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load booking context: %w", err)
	}
	if nonTeachingInt == 1 {
		return nil, ErrNonTeachingSession
	}
	if !competencyCourseNull.Valid {
		return nil, ErrCompetencyNotFound
	}
	if domain.CourseTypeID(competencyCourseNull.String) != bookingCourse {
		return nil, ErrCompetencyWrongCourse
	}

	now := time.Now().UTC()
	// Upsert via INSERT … ON CONFLICT(booking_id, competency_id).
	id := domain.NewID()
	_, err = scope.Conn().ExecContext(ctx, `
		INSERT INTO progress_records
		    (id, school_id, booking_id, student_id, competency_id, status, recorded_at, recorded_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(booking_id, competency_id) DO UPDATE SET
		    status = excluded.status,
		    recorded_at = excluded.recorded_at,
		    recorded_by = excluded.recorded_by
	`, id, string(scope.SchoolID()), string(req.BookingID), string(studentID),
		string(req.CompetencyID), req.Status,
		now.Format(time.RFC3339), string(req.RecordedBy))
	if err != nil {
		return nil, fmt.Errorf("upsert progress: %w", err)
	}

	// Re-read the row to get the canonical (possibly pre-existing) id.
	var rec ProgressRecord
	var recordedStr string
	err = scope.Conn().QueryRowContext(ctx, `
		SELECT id, booking_id, student_id, competency_id, status, recorded_at, recorded_by
		FROM progress_records
		WHERE booking_id = ? AND competency_id = ? AND school_id = ?
	`, string(req.BookingID), string(req.CompetencyID), string(scope.SchoolID())).Scan(
		&rec.ID, &rec.BookingID, &rec.StudentID, &rec.CompetencyID,
		&rec.Status, &recordedStr, &rec.RecordedBy,
	)
	if err != nil {
		return nil, fmt.Errorf("read back progress: %w", err)
	}
	rec.RecordedAt, _ = time.Parse(time.RFC3339, recordedStr)
	return &rec, nil
}

// ----- Session detail (the instructor's session screen) -----

type SessionDetail struct {
	SessionID        domain.SessionID
	CourseTypeID     domain.CourseTypeID
	CourseName       string
	NonTeaching      bool
	InstructorID     domain.UserID
	InstructorName   string
	LocationID       domain.LocationID
	LocationName     string
	StartsAt         time.Time
	EndsAt           time.Time
	Capacity         int
	Status           string
	Bookings         []BookingDetail
	CourseCompetencies []CompetencyTemplate
}

type CompetencyTemplate struct {
	ID        domain.CompetencyID
	Label     string
	SortOrder int
}

type BookingDetail struct {
	BookingID        domain.BookingID
	Status           domain.BookingStatus
	BikeID           domain.BikeID
	BikeNickname     string
	StudentID        domain.UserID
	StudentName      string
	StudentPhone     string
	SafetyFlags      []SafetyFlag
	OutstandingPence domain.Money
	Notes            string
	Competencies     map[domain.CompetencyID]string // competencyID → status
}

type SafetyFlag struct {
	ID   domain.StudentNoteID
	Body string
}

func GetSessionDetail(ctx context.Context, scope *tenant.Scope, sessionID domain.SessionID) (*SessionDetail, error) {
	// 1) Session + course type
	const sessQ = `
		SELECT s.id, s.course_type_id, ct.name, COALESCE(ct.non_teaching, 0),
		       s.instructor_id, COALESCE(u.name, ''),
		       s.location_id, COALESCE(l.name, ''),
		       s.starts_at, s.ends_at, s.capacity, s.status
		FROM sessions s
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN users u    ON u.id = s.instructor_id   AND u.school_id = s.school_id
		LEFT JOIN locations l ON l.id = s.location_id    AND l.school_id = s.school_id
		WHERE s.id = ? AND s.school_id = ?
	`
	var (
		sd                SessionDetail
		nonTeachingInt    int
		startsStr, endStr string
	)
	err := scope.Conn().QueryRowContext(ctx, sessQ, string(sessionID), string(scope.SchoolID())).Scan(
		&sd.SessionID, &sd.CourseTypeID, &sd.CourseName, &nonTeachingInt,
		&sd.InstructorID, &sd.InstructorName,
		&sd.LocationID, &sd.LocationName,
		&startsStr, &endStr, &sd.Capacity, &sd.Status,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSessionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load session: %w", err)
	}
	sd.NonTeaching = nonTeachingInt == 1
	sd.StartsAt, _ = time.Parse(time.RFC3339, startsStr)
	sd.EndsAt, _ = time.Parse(time.RFC3339, endStr)

	// 2) Course competencies template (skipped for non_teaching)
	if !sd.NonTeaching {
		comps, err := loadCourseCompetencies(ctx, scope, sd.CourseTypeID)
		if err != nil {
			return nil, err
		}
		sd.CourseCompetencies = comps
	}

	// 3) Bookings + per-student aggregates
	const bkQ = `
		SELECT b.id, b.status, COALESCE(b.bike_id, ''), COALESCE(bk.nickname, ''),
		       b.student_id, u.name, COALESCE(u.phone, ''),
		       COALESCE(b.notes, '')
		FROM bookings b
		LEFT JOIN bikes bk ON bk.id = b.bike_id AND bk.school_id = b.school_id
		JOIN users u ON u.id = b.student_id AND u.school_id = b.school_id
		WHERE b.session_id = ? AND b.school_id = ?
		  AND b.status <> 'cancelled'
		ORDER BY u.name ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, bkQ, string(sd.SessionID), string(scope.SchoolID()))
	if err != nil {
		return nil, fmt.Errorf("load bookings: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var bd BookingDetail
		if err := rows.Scan(&bd.BookingID, &bd.Status, &bd.BikeID, &bd.BikeNickname,
			&bd.StudentID, &bd.StudentName, &bd.StudentPhone, &bd.Notes); err != nil {
			return nil, err
		}
		sd.Bookings = append(sd.Bookings, bd)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// 4) Augment each booking with safety flags + outstanding + competencies
	for i := range sd.Bookings {
		studentID := sd.Bookings[i].StudentID
		flags, err := loadSafetyFlags(ctx, scope, studentID)
		if err != nil {
			return nil, err
		}
		sd.Bookings[i].SafetyFlags = flags

		bal, err := loadOutstanding(ctx, scope, studentID)
		if err != nil {
			return nil, err
		}
		sd.Bookings[i].OutstandingPence = bal

		if !sd.NonTeaching {
			rec, err := loadBookingCompetencyStatuses(ctx, scope, sd.Bookings[i].BookingID)
			if err != nil {
				return nil, err
			}
			sd.Bookings[i].Competencies = rec
		}
	}
	return &sd, nil
}

func loadCourseCompetencies(ctx context.Context, scope *tenant.Scope, ctID domain.CourseTypeID) ([]CompetencyTemplate, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, label, sort_order FROM competencies
		WHERE school_id = ? AND course_type_id = ?
		ORDER BY sort_order ASC, label ASC
	`, string(scope.SchoolID()), string(ctID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CompetencyTemplate
	for rows.Next() {
		var c CompetencyTemplate
		if err := rows.Scan(&c.ID, &c.Label, &c.SortOrder); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func loadSafetyFlags(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) ([]SafetyFlag, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, body FROM student_notes
		WHERE school_id = ? AND student_id = ? AND kind = 'safety_flag' AND is_active = 1
		ORDER BY created_at ASC
	`, string(scope.SchoolID()), string(studentID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SafetyFlag
	for rows.Next() {
		var f SafetyFlag
		if err := rows.Scan(&f.ID, &f.Body); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func loadOutstanding(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) (domain.Money, error) {
	var charged, paid sql.NullInt64
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT
		    (SELECT COALESCE(SUM(amount_pence), 0) FROM charges
		      WHERE school_id = ? AND student_id = ? AND voided_at IS NULL),
		    (SELECT COALESCE(SUM(amount_pence), 0) FROM payments
		      WHERE school_id = ? AND student_id = ? AND voided_at IS NULL)
	`, string(scope.SchoolID()), string(studentID),
		string(scope.SchoolID()), string(studentID),
	).Scan(&charged, &paid)
	if err != nil {
		return 0, err
	}
	return domain.Money(charged.Int64 - paid.Int64), nil
}

func loadBookingCompetencyStatuses(ctx context.Context, scope *tenant.Scope, bookingID domain.BookingID) (map[domain.CompetencyID]string, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT competency_id, status FROM progress_records
		WHERE school_id = ? AND booking_id = ?
	`, string(scope.SchoolID()), string(bookingID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[domain.CompetencyID]string{}
	for rows.Next() {
		var (
			cid domain.CompetencyID
			st  string
		)
		if err := rows.Scan(&cid, &st); err != nil {
			return nil, err
		}
		out[cid] = st
	}
	return out, rows.Err()
}

// ----- Student progress rollup (student app) -----

// StudentProgress aggregates a student's assessed competencies per course.
// "Latest status" per competency = the most recent recorded assessment
// across any of the student's bookings on that course.
type StudentProgress struct {
	StudentID domain.UserID
	Courses   []CourseProgress
}

type CourseProgress struct {
	CourseTypeID      domain.CourseTypeID
	CourseName        string
	Competencies      []CompetencyProgress
	TotalCompetencies int
	CompetentCount    int
	NeedsWorkCount    int
}

type CompetencyProgress struct {
	CompetencyID domain.CompetencyID
	Label        string
	Status       string    // 'not_assessed' if never recorded
	LastSeen     time.Time // zero if not_assessed
}

func GetStudentProgress(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) (*StudentProgress, error) {
	// Verify student exists
	var n int
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT 1 FROM users WHERE id = ? AND school_id = ? AND role = 'student'`,
		string(studentID), string(scope.SchoolID()),
	).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrStudentNotFound
	}
	if err != nil {
		return nil, err
	}

	// Which courses has the student ever booked (any status, even cancelled
	// — gives the UI all the courses worth showing).
	courses, err := studentCourses(ctx, scope, studentID)
	if err != nil {
		return nil, err
	}

	out := &StudentProgress{StudentID: studentID}
	for _, c := range courses {
		cp, err := courseProgress(ctx, scope, studentID, c.ID, c.Name)
		if err != nil {
			return nil, err
		}
		out.Courses = append(out.Courses, *cp)
	}
	return out, nil
}

type courseRow struct {
	ID   domain.CourseTypeID
	Name string
}

func studentCourses(ctx context.Context, scope *tenant.Scope, studentID domain.UserID) ([]courseRow, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT DISTINCT ct.id, ct.name
		FROM bookings b
		JOIN sessions s ON s.id = b.session_id AND s.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		WHERE b.school_id = ? AND b.student_id = ? AND COALESCE(ct.non_teaching, 0) = 0
		ORDER BY ct.name ASC
	`, string(scope.SchoolID()), string(studentID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []courseRow
	for rows.Next() {
		var c courseRow
		if err := rows.Scan(&c.ID, &c.Name); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func courseProgress(ctx context.Context, scope *tenant.Scope, studentID domain.UserID, courseID domain.CourseTypeID, courseName string) (*CourseProgress, error) {
	cp := &CourseProgress{CourseTypeID: courseID, CourseName: courseName}

	// All competencies for this course, with the student's latest status (if any).
	const q = `
		SELECT c.id, c.label,
		       latest.status AS status, COALESCE(latest.recorded_at, '') AS recorded_at
		FROM competencies c
		LEFT JOIN (
		    SELECT competency_id, status, recorded_at
		    FROM progress_records pr
		    WHERE pr.school_id = ? AND pr.student_id = ?
		      AND pr.recorded_at = (
		        SELECT MAX(recorded_at) FROM progress_records pr2
		        WHERE pr2.school_id = pr.school_id
		          AND pr2.student_id = pr.student_id
		          AND pr2.competency_id = pr.competency_id
		      )
		) latest ON latest.competency_id = c.id
		WHERE c.school_id = ? AND c.course_type_id = ?
		ORDER BY c.sort_order ASC, c.label ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q,
		string(scope.SchoolID()), string(studentID),
		string(scope.SchoolID()), string(courseID),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			c          CompetencyProgress
			statusNull sql.NullString
			whenStr    string
		)
		if err := rows.Scan(&c.CompetencyID, &c.Label, &statusNull, &whenStr); err != nil {
			return nil, err
		}
		if statusNull.Valid {
			c.Status = statusNull.String
		} else {
			c.Status = StatusNotAssessed
		}
		if whenStr != "" {
			c.LastSeen, _ = time.Parse(time.RFC3339, whenStr)
		}
		cp.Competencies = append(cp.Competencies, c)
		switch c.Status {
		case StatusCompetent:
			cp.CompetentCount++
		case StatusNeedsWork:
			cp.NeedsWorkCount++
		}
		cp.TotalCompetencies++
	}
	return cp, rows.Err()
}
