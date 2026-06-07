// Package booking implements the §4 booking constraint engine.
//
// A booking is valid only when ALL of these hold simultaneously, checked
// inside a single IMMEDIATE transaction so two concurrent attempts can't
// both grab the last slot or last suitable bike:
//
//  1. Session exists, belongs to the tenant, is in the future, and is bookable.
//  2. Student exists, belongs to the tenant, and has 'active' account status.
//  3. Instructor is qualified for this course type.
//  4. Capacity isn't exceeded — and a suitable bike is actually free.
//     Real bookable limit = min(capacity − active bookings, suitable free bikes).
//  5. If a specific bike was requested, it must be in the suitable-free set.
//
// Eligibility prerequisites (CBT held, theory passed) are SURFACED as
// non-blocking advisories — never as gates. Per plan §4: "no licensing-rules
// engine ... the system records the facts and at most offers soft,
// non-blocking advisory prompts." This is the same warn-don't-block pattern
// used everywhere else in Kickstand.
package booking

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/notify"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Request describes a booking attempt. BikeID="" means "auto-assign a
// suitable free bike" — the assignment happens inside the same transaction
// as the capacity check, so we never assign a bike that's not actually free.
type Request struct {
	SessionID domain.SessionID
	StudentID domain.UserID
	BikeID    domain.BikeID // "" = auto-assign
}

// Result of a successful booking. Advisories are non-blocking warnings the
// caller should surface in the UI ("⚠ Your CBT expires before this session").
type Result struct {
	Booking    domain.Booking
	Advisories []Advisory
}

// Advisory codes are stable; messages are humanised. The UI may translate or
// restyle based on the code.
type Advisory struct {
	Code    string
	Message string
}

const (
	AdvisoryCBTMissing      = "cbt_missing"
	AdvisoryCBTExpiringSoon = "cbt_expiring_soon"
	AdvisoryCBTExpired      = "cbt_expired_before_session"
	AdvisoryTheoryMissing   = "theory_missing"
	AdvisoryCrossSiteBike   = "cross_site_bike"
)

// Typed errors per failure mode. Callers branch on these to render the right
// message (e.g. "Full" vs "No suitable bike" — same root cause from raw
// capacity's perspective, but quite different stories for the user).
var (
	ErrSessionNotFound      = errors.New("booking: session not found in this school")
	ErrStudentNotFound      = errors.New("booking: student not found in this school")
	ErrSessionNotBookable   = errors.New("booking: session is cancelled or completed")
	ErrSessionInPast        = errors.New("booking: session has already started")
	ErrStudentNotActive     = errors.New("booking: student is not approved to book")
	ErrAlreadyBooked        = errors.New("booking: student already booked on this session")
	ErrCapacityFull         = errors.New("booking: session capacity is full")
	ErrNoSuitableBike       = errors.New("booking: no suitable bike is available")
	ErrBikeNotSuitable      = errors.New("booking: chosen bike is not suitable for this session")
	ErrInstructorUnqualified = errors.New("booking: instructor is not qualified for this course type")
)

// Book runs the constraint engine and creates the booking row.
//
// Pass nowFn to control "what time is it?" — defaults to time.Now() but
// tests use a fixed time so they don't drift over weekends.
func Book(ctx context.Context, scope *tenant.Scope, req Request) (*Result, error) {
	return BookAt(ctx, scope, req, time.Now)
}

// BookAt is the testable form — exposes the clock as a parameter.
func BookAt(ctx context.Context, scope *tenant.Scope, req Request, nowFn func() time.Time) (*Result, error) {
	var result *Result
	err := scope.WithTx(ctx, func(tx *tenant.Scope) error {
		r, err := bookInTx(ctx, tx, req, nowFn())
		if err != nil {
			return err
		}
		// Emit the booking.created event + student notification inside the
		// same transaction so a notification can never refer to a booking
		// that doesn't exist (and vice-versa).
		name, _ := sessionCourseName(ctx, tx, r.Booking.SessionID)
		if err := notify.OnBookingCreated(ctx, tx, r.Booking, name); err != nil {
			return err
		}
		result = r
		return nil
	})
	return result, err
}

// sessionCourseName fetches the human-friendly course name for a session.
// Used by notify payloads so the bell list can render "CBT 125" instead of
// just an opaque session id.
func sessionCourseName(ctx context.Context, scope *tenant.Scope, id domain.SessionID) (string, error) {
	var name string
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT ct.name FROM sessions s
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		WHERE s.id = ? AND s.school_id = ?
	`, string(id), string(scope.SchoolID())).Scan(&name)
	if err != nil {
		return "", err
	}
	return name, nil
}

// sessionInstructor fetches the instructor on a session — used by cancel
// notify to ping the instructor when the student cancels.
func sessionInstructor(ctx context.Context, scope *tenant.Scope, id domain.SessionID) (domain.UserID, error) {
	var u domain.UserID
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT instructor_id FROM sessions WHERE id = ? AND school_id = ?`,
		string(id), string(scope.SchoolID())).Scan(&u)
	if err != nil {
		return "", err
	}
	return u, nil
}

// sessionRow carries everything the engine needs to make a decision in one
// fetch — saves round-trips and avoids forgotten WHERE clauses.
type sessionRow struct {
	id                   domain.SessionID
	schoolID             domain.SchoolID
	courseTypeID         domain.CourseTypeID
	instructorID         domain.UserID
	locationID           domain.LocationID
	startsAt             time.Time
	endsAt               time.Time
	capacity             int
	status               string
	requiredBikeCategory string // may be empty
	nonTeaching          bool
}

type studentRow struct {
	id                domain.UserID
	accountStatus     string
	transmissionPref  string // empty if not set
	cbtHeld           bool
	cbtExpiresOn      string // YYYY-MM-DD or empty
	theoryPassed      bool
	hasProfile        bool
}

func bookInTx(ctx context.Context, tx *tenant.Scope, req Request, now time.Time) (*Result, error) {
	sess, err := loadSession(ctx, tx, req.SessionID)
	if err != nil {
		return nil, err
	}
	if sess.status != "scheduled" {
		return nil, ErrSessionNotBookable
	}
	if !sess.startsAt.After(now) {
		return nil, ErrSessionInPast
	}

	stu, err := loadStudent(ctx, tx, req.StudentID)
	if err != nil {
		return nil, err
	}
	if stu.accountStatus != string(domain.AccountActive) {
		return nil, ErrStudentNotActive
	}

	// Defensive: confirm the instructor on the session is qualified for the
	// course type. This is invariant-checked at session creation, but a
	// later qualification revocation could leave a stale session.
	qualified, err := instructorIsQualified(ctx, tx, sess.instructorID, sess.courseTypeID)
	if err != nil {
		return nil, err
	}
	if !qualified {
		return nil, ErrInstructorUnqualified
	}

	activeBookings, err := countActiveBookings(ctx, tx, sess.id)
	if err != nil {
		return nil, err
	}
	if activeBookings >= sess.capacity {
		return nil, ErrCapacityFull
	}

	// Find the set of suitable free bikes for this session window. Honest
	// capacity = min(capacity − activeBookings, len(suitableFree)).
	suitable, err := findSuitableFreeBikes(ctx, tx, sess, stu.transmissionPref)
	if err != nil {
		return nil, err
	}
	if len(suitable) == 0 {
		return nil, ErrNoSuitableBike
	}

	var assignedBike domain.BikeID
	var crossSite bool
	if req.BikeID != "" {
		chosen, ok := pickRequestedBike(suitable, req.BikeID)
		if !ok {
			return nil, ErrBikeNotSuitable
		}
		assignedBike = chosen.id
		crossSite = chosen.currentLocationID != sess.locationID
	} else {
		// Auto-assign: prefer same-location bikes (no cross-site move needed),
		// then lowest id for determinism.
		chosen := suitable[0]
		assignedBike = chosen.id
		crossSite = chosen.currentLocationID != sess.locationID
	}

	booking, err := insertBooking(ctx, tx, req, sess, assignedBike, now)
	if err != nil {
		return nil, err
	}

	return &Result{
		Booking:    booking,
		Advisories: buildAdvisories(sess, stu, crossSite),
	}, nil
}

type bikeCandidate struct {
	id                domain.BikeID
	currentLocationID domain.LocationID
}

func pickRequestedBike(suitable []bikeCandidate, want domain.BikeID) (bikeCandidate, bool) {
	for _, c := range suitable {
		if c.id == want {
			return c, true
		}
	}
	return bikeCandidate{}, false
}

func loadSession(ctx context.Context, tx *tenant.Scope, id domain.SessionID) (*sessionRow, error) {
	const q = `
		SELECT s.id, s.school_id, s.course_type_id, s.instructor_id, s.location_id,
		       s.starts_at, s.ends_at, s.capacity, s.status,
		       COALESCE(ct.required_bike_category, ''), ct.non_teaching
		FROM sessions s
		JOIN course_types ct
		     ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		WHERE s.id = ? AND s.school_id = ?
	`
	row := tx.Conn().QueryRowContext(ctx, q, string(id), string(tx.SchoolID()))
	var s sessionRow
	var startsStr, endsStr string
	var nonTeachingInt int
	err := row.Scan(
		&s.id, &s.schoolID, &s.courseTypeID, &s.instructorID, &s.locationID,
		&startsStr, &endsStr, &s.capacity, &s.status,
		&s.requiredBikeCategory, &nonTeachingInt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSessionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load session: %w", err)
	}
	s.startsAt, err = parseTime(startsStr)
	if err != nil {
		return nil, fmt.Errorf("parse session starts_at: %w", err)
	}
	s.endsAt, err = parseTime(endsStr)
	if err != nil {
		return nil, fmt.Errorf("parse session ends_at: %w", err)
	}
	s.nonTeaching = nonTeachingInt == 1
	return &s, nil
}

func loadStudent(ctx context.Context, tx *tenant.Scope, id domain.UserID) (*studentRow, error) {
	const q = `
		SELECT u.id, u.account_status,
		       COALESCE(sp.transmission_preference, ''),
		       COALESCE(sp.cbt_certificate_held, 0),
		       COALESCE(sp.cbt_expires_on, ''),
		       COALESCE(sp.theory_passed, 0),
		       sp.user_id IS NOT NULL
		FROM users u
		LEFT JOIN student_profiles sp
		     ON sp.user_id = u.id AND sp.school_id = u.school_id
		WHERE u.id = ? AND u.school_id = ? AND u.role = 'student'
	`
	row := tx.Conn().QueryRowContext(ctx, q, string(id), string(tx.SchoolID()))
	var s studentRow
	var cbtHeldInt, theoryInt, hasProfileInt int
	err := row.Scan(&s.id, &s.accountStatus, &s.transmissionPref,
		&cbtHeldInt, &s.cbtExpiresOn, &theoryInt, &hasProfileInt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrStudentNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load student: %w", err)
	}
	s.cbtHeld = cbtHeldInt == 1
	s.theoryPassed = theoryInt == 1
	s.hasProfile = hasProfileInt == 1
	return &s, nil
}

func instructorIsQualified(ctx context.Context, tx *tenant.Scope, instructorID domain.UserID, courseTypeID domain.CourseTypeID) (bool, error) {
	const q = `
		SELECT 1 FROM instructor_qualifications
		WHERE school_id = ? AND instructor_id = ? AND course_type_id = ?
	`
	row := tx.Conn().QueryRowContext(ctx, q, string(tx.SchoolID()), string(instructorID), string(courseTypeID))
	var ok int
	err := row.Scan(&ok)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("instructor qualified check: %w", err)
	}
	return true, nil
}

func countActiveBookings(ctx context.Context, tx *tenant.Scope, sessionID domain.SessionID) (int, error) {
	const q = `
		SELECT COUNT(*) FROM bookings
		WHERE school_id = ? AND session_id = ?
		  AND status IN ('booked', 'needs_reassignment')
	`
	var n int
	err := tx.Conn().QueryRowContext(ctx, q, string(tx.SchoolID()), string(sessionID)).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("count bookings: %w", err)
	}
	return n, nil
}

// findSuitableFreeBikes is the heart of the engine. The same predicate runs
// reactively in disruption handling to find swap candidates.
//
// "Suitable" = right category + (optionally) right transmission + status ready
// + not in an unavailability window overlapping the session + not held by an
// active booking whose session overlaps. Location is NOT a filter here — bikes
// at other sites are still candidates, surfaced with a `cross_site_bike`
// advisory. The MVP doesn't model precise cross-site move feasibility.
func findSuitableFreeBikes(ctx context.Context, tx *tenant.Scope, sess *sessionRow, transmissionPref string) ([]bikeCandidate, error) {
	startStr := sess.startsAt.UTC().Format(time.RFC3339)
	endStr := sess.endsAt.UTC().Format(time.RFC3339)

	const q = `
		SELECT b.id, b.current_location_id
		FROM bikes b
		WHERE b.school_id = ?
		  AND b.status = 'ready'
		  AND (? = '' OR b.category = ?)
		  AND (? = '' OR b.transmission = ?)
		  AND NOT EXISTS (
		    SELECT 1 FROM bike_unavailability bu
		    WHERE bu.school_id = b.school_id
		      AND bu.bike_id = b.id
		      AND bu.starts_at < ?
		      AND bu.ends_at > ?
		  )
		  AND NOT EXISTS (
		    SELECT 1 FROM bookings bk
		    JOIN sessions ss ON ss.id = bk.session_id AND ss.school_id = bk.school_id
		    WHERE bk.school_id = b.school_id
		      AND bk.bike_id = b.id
		      AND bk.status IN ('booked', 'needs_reassignment')
		      AND ss.starts_at < ?
		      AND ss.ends_at > ?
		  )
		ORDER BY (b.current_location_id = ?) DESC, b.id ASC
	`
	rows, err := tx.Conn().QueryContext(ctx, q,
		string(tx.SchoolID()),
		sess.requiredBikeCategory, sess.requiredBikeCategory,
		transmissionPref, transmissionPref,
		endStr, startStr,
		endStr, startStr,
		string(sess.locationID),
	)
	if err != nil {
		return nil, fmt.Errorf("query suitable bikes: %w", err)
	}
	defer rows.Close()

	var out []bikeCandidate
	for rows.Next() {
		var c bikeCandidate
		if err := rows.Scan(&c.id, &c.currentLocationID); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func insertBooking(ctx context.Context, tx *tenant.Scope, req Request, sess *sessionRow, bikeID domain.BikeID, now time.Time) (domain.Booking, error) {
	booking := domain.Booking{
		ID:        domain.BookingID(domain.NewID()),
		SchoolID:  tx.SchoolID(),
		SessionID: sess.id,
		StudentID: req.StudentID,
		BikeID:    bikeID,
		Status:    domain.BookingBooked,
		CreatedAt: now.UTC(),
	}

	const q = `
		INSERT INTO bookings (id, school_id, session_id, student_id, bike_id, status, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`
	_, err := tx.Conn().ExecContext(ctx, q,
		string(booking.ID), string(booking.SchoolID), string(booking.SessionID),
		string(booking.StudentID), string(booking.BikeID),
		string(booking.Status), booking.CreatedAt.Format(time.RFC3339),
	)
	if err != nil {
		// The UNIQUE (school_id, session_id, student_id) constraint surfaces
		// "this student is already booked on this session". Catch it as a
		// typed error rather than a raw SQLite message.
		if isUniqueViolation(err) {
			return domain.Booking{}, ErrAlreadyBooked
		}
		return domain.Booking{}, fmt.Errorf("insert booking: %w", err)
	}
	return booking, nil
}

func buildAdvisories(sess *sessionRow, stu *studentRow, crossSite bool) []Advisory {
	var out []Advisory
	if crossSite {
		out = append(out, Advisory{
			Code:    AdvisoryCrossSiteBike,
			Message: "Bike is currently at another site — will need to be moved before this session.",
		})
	}
	// Test days don't need teaching-prereq nudges; the session itself is the test.
	if sess.nonTeaching {
		return out
	}
	if !stu.hasProfile {
		return out
	}
	if !stu.cbtHeld {
		out = append(out, Advisory{
			Code:    AdvisoryCBTMissing,
			Message: "No CBT certificate on file — most practical courses require one.",
		})
	}
	if !stu.theoryPassed {
		out = append(out, Advisory{
			Code:    AdvisoryTheoryMissing,
			Message: "Theory test not yet passed.",
		})
	}
	if stu.cbtExpiresOn != "" {
		if d, err := time.Parse("2006-01-02", stu.cbtExpiresOn); err == nil {
			if d.Before(sess.startsAt) {
				out = append(out, Advisory{
					Code:    AdvisoryCBTExpired,
					Message: "CBT expires before this session — renew before the date.",
				})
			} else if d.Sub(sess.startsAt) < 30*24*time.Hour {
				out = append(out, Advisory{
					Code:    AdvisoryCBTExpiringSoon,
					Message: "CBT expires soon — consider renewing.",
				})
			}
		}
	}
	return out
}

func parseTime(s string) (time.Time, error) {
	// Accept both RFC3339 ('2026-06-06T14:00:00Z') and the SQLite default
	// 'YYYY-MM-DD HH:MM:SS' shape, since we may eventually read seed data
	// in either form.
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), nil
	}
	if t, err := time.Parse("2006-01-02 15:04:05", s); err == nil {
		return t.UTC(), nil
	}
	return time.Time{}, fmt.Errorf("unrecognised time format: %q", s)
}

// isUniqueViolation detects SQLite's "UNIQUE constraint failed" error.
// modernc.org/sqlite returns errors as *sqlite.Error with a Code() method,
// but rather than depend on the concrete type, string-match is robust across
// drivers (the message format is part of SQLite's stable surface).
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return contains(msg, "UNIQUE constraint failed") || contains(msg, "constraint failed: UNIQUE")
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
