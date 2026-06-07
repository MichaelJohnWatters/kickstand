package booking

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// SessionListing is one row in the browse-sessions response. HonestCapacity
// is the bookable-now number: min(capacity − active bookings, suitable free
// bikes). That's the headline behaviour from the plan — never show raw
// capacity to students.
type SessionListing struct {
	SessionID         domain.SessionID
	CourseTypeID      domain.CourseTypeID
	CourseCode        string
	CourseName        string
	CourseAccentColour string // hex like "#6366F1"; "" → client fallback
	NonTeaching       bool
	InstructorID      domain.UserID
	InstructorName    string
	LocationID        domain.LocationID
	LocationName      string
	StartsAt          time.Time
	EndsAt            time.Time
	Capacity          int
	ActiveBookings    int
	SuitableFreeBikes int
	HonestCapacity    int
	PricePence        int64
}

// MyBookingRow is the per-booking shape used by the student "My bookings"
// screen. Carries enough denormalised context (course, location, instructor,
// times) to render a card without a second round-trip.
type MyBookingRow struct {
	BookingID          domain.BookingID
	Status             domain.BookingStatus
	BikeID             domain.BikeID
	BikeNickname       string
	SessionID          domain.SessionID
	CourseTypeID       domain.CourseTypeID
	CourseCode         string
	CourseName         string
	CourseAccentColour string
	NonTeaching        bool
	InstructorID       domain.UserID
	InstructorName     string
	LocationID         domain.LocationID
	LocationName       string
	StartsAt           time.Time
	EndsAt             time.Time
	PricePence         domain.Money
	CreatedAt          time.Time
	CancelledAt        time.Time // zero if not cancelled
	CancelledBy        string
	CancellationReason string
}

// ListStudentBookings returns a student's bookings filtered by when:
//   "upcoming"  active (booked / needs_reassignment / completed if future)
//   "past"      everything else (cancelled, completed, no_show, or past start)
//   ""/"all"    no filter, most recent first
//
// Cancelled bookings always appear under "past" regardless of date.
func ListStudentBookings(ctx context.Context, scope *tenant.Scope, studentID domain.UserID, when string, now time.Time) ([]MyBookingRow, error) {
	const base = `
		SELECT b.id, b.status, COALESCE(b.bike_id, ''), COALESCE(bk.nickname, ''),
		       s.id, s.course_type_id, COALESCE(ct.code, ''), COALESCE(ct.name, ''),
		       COALESCE(ct.accent_colour, ''),
		       COALESCE(ct.non_teaching, 0),
		       s.instructor_id, COALESCE(u.name, ''),
		       s.location_id, COALESCE(l.name, ''),
		       s.starts_at, s.ends_at, COALESCE(ct.price_pence, 0),
		       b.created_at, COALESCE(b.cancelled_at, ''),
		       COALESCE(b.cancelled_by, ''), COALESCE(b.cancellation_reason, '')
		FROM bookings b
		JOIN sessions s     ON s.id = b.session_id AND s.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN bikes bk   ON bk.id = b.bike_id           AND bk.school_id = b.school_id
		LEFT JOIN users u    ON u.id = s.instructor_id      AND u.school_id = s.school_id
		LEFT JOIN locations l ON l.id = s.location_id       AND l.school_id = s.school_id
		WHERE b.school_id = ? AND b.student_id = ?
	`
	args := []any{string(scope.SchoolID()), string(studentID)}
	var where string
	switch when {
	case "upcoming":
		// Active and starting in the future.
		where = ` AND b.status IN ('booked', 'needs_reassignment') AND s.starts_at >= ?`
		args = append(args, now.UTC().Format(time.RFC3339))
	case "past":
		// Everything that's done, cancelled, or has started.
		where = ` AND (b.status IN ('cancelled', 'completed', 'no_show') OR s.starts_at < ?)`
		args = append(args, now.UTC().Format(time.RFC3339))
	}
	order := ` ORDER BY s.starts_at ASC`
	if when == "past" || when == "" {
		order = ` ORDER BY s.starts_at DESC`
	}

	rows, err := scope.Conn().QueryContext(ctx, base+where+order, args...)
	if err != nil {
		return nil, fmt.Errorf("query my bookings: %w", err)
	}
	defer rows.Close()
	var out []MyBookingRow
	for rows.Next() {
		var (
			r              MyBookingRow
			nonTeachingInt int
			startsStr, endsStr, createdStr, cancelledStr string
		)
		if err := rows.Scan(
			&r.BookingID, &r.Status, &r.BikeID, &r.BikeNickname,
			&r.SessionID, &r.CourseTypeID, &r.CourseCode, &r.CourseName,
			&r.CourseAccentColour,
			&nonTeachingInt,
			&r.InstructorID, &r.InstructorName,
			&r.LocationID, &r.LocationName,
			&startsStr, &endsStr, &r.PricePence,
			&createdStr, &cancelledStr,
			&r.CancelledBy, &r.CancellationReason,
		); err != nil {
			return nil, err
		}
		r.NonTeaching = nonTeachingInt == 1
		r.StartsAt, _ = parseTime(startsStr)
		r.EndsAt, _ = parseTime(endsStr)
		r.CreatedAt, _ = parseTime(createdStr)
		if cancelledStr != "" {
			r.CancelledAt, _ = parseTime(cancelledStr)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ListUpcomingSessions returns scheduled sessions whose start falls in
// [from, to). Annotates each with honest bike-aware capacity.
//
// This is the data behind the student "Browse & book" flow and the admin
// master calendar. Filters are kept minimal for the MVP — location filter
// is optional, more refinement can come from the UI side via this list.
func ListUpcomingSessions(ctx context.Context, scope *tenant.Scope, from, to time.Time, locationID domain.LocationID) ([]SessionListing, error) {
	const q = `
		SELECT s.id, s.course_type_id, COALESCE(ct.code,''), COALESCE(ct.name,''),
		       COALESCE(ct.accent_colour, ''),
		       COALESCE(ct.non_teaching, 0), COALESCE(ct.price_pence, 0),
		       s.instructor_id, COALESCE(u.name, ''),
		       s.location_id, COALESCE(l.name, ''),
		       s.starts_at, s.ends_at, s.capacity,
		       COALESCE(ct.required_bike_category, '')
		FROM sessions s
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN users u    ON u.id = s.instructor_id    AND u.school_id = s.school_id
		LEFT JOIN locations l ON l.id = s.location_id     AND l.school_id = s.school_id
		WHERE s.school_id = ?
		  AND s.status = 'scheduled'
		  AND s.starts_at >= ?
		  AND s.starts_at <  ?
		  AND (? = '' OR s.location_id = ?)
		ORDER BY s.starts_at ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q,
		string(scope.SchoolID()),
		from.UTC().Format(time.RFC3339),
		to.UTC().Format(time.RFC3339),
		string(locationID), string(locationID),
	)
	if err != nil {
		return nil, fmt.Errorf("query sessions: %w", err)
	}
	defer rows.Close()

	type rowOut struct {
		listing      SessionListing
		requiredCat  string
	}
	var collected []rowOut
	for rows.Next() {
		var (
			r              rowOut
			startsStr      string
			endsStr        string
			nonTeachingInt int
		)
		err := rows.Scan(
			&r.listing.SessionID, &r.listing.CourseTypeID, &r.listing.CourseCode, &r.listing.CourseName,
			&r.listing.CourseAccentColour,
			&nonTeachingInt, &r.listing.PricePence,
			&r.listing.InstructorID, &r.listing.InstructorName,
			&r.listing.LocationID, &r.listing.LocationName,
			&startsStr, &endsStr, &r.listing.Capacity,
			&r.requiredCat,
		)
		if err != nil {
			return nil, err
		}
		r.listing.NonTeaching = nonTeachingInt == 1
		r.listing.StartsAt, err = parseTime(startsStr)
		if err != nil {
			return nil, fmt.Errorf("parse starts_at: %w", err)
		}
		r.listing.EndsAt, err = parseTime(endsStr)
		if err != nil {
			return nil, fmt.Errorf("parse ends_at: %w", err)
		}
		collected = append(collected, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Annotate each session with active bookings + suitable bike count.
	// One-shot per session, fine at MVP scale (week views are tens of rows).
	out := make([]SessionListing, 0, len(collected))
	for _, r := range collected {
		active, err := countActiveBookings(ctx, scope, r.listing.SessionID)
		if err != nil {
			return nil, err
		}
		sess := &sessionRow{
			id:                   r.listing.SessionID,
			startsAt:             r.listing.StartsAt,
			endsAt:               r.listing.EndsAt,
			locationID:           r.listing.LocationID,
			requiredBikeCategory: r.requiredCat,
		}
		bikes, err := findSuitableFreeBikes(ctx, scope, sess, "")
		if err != nil {
			return nil, err
		}
		r.listing.ActiveBookings = active
		r.listing.SuitableFreeBikes = len(bikes)
		left := r.listing.Capacity - active
		if len(bikes) < left {
			left = len(bikes)
		}
		if left < 0 {
			left = 0
		}
		r.listing.HonestCapacity = left
		out = append(out, r.listing)
	}
	return out, nil
}

// SuitableBikeRow is one bike in the picker list for a session. Carries the
// rich detail the booking UI needs — nickname, registration, engine size,
// transmission, current location — plus a flag for cross-site bikes so the
// UI can warn about a move.
type SuitableBikeRow struct {
	BikeID              domain.BikeID
	Nickname            string
	Registration        string
	Category            domain.LicenceCategory
	Transmission        domain.Transmission
	EngineCC            int
	CurrentLocationID   domain.LocationID
	CurrentLocationName string
	IsCrossSite         bool // bike is not at the session's location
}

// SuitableBikesForSession returns every ready bike that could be assigned
// to the given session, honouring the student's transmission preference
// when one is recorded. Used by the booking-flow bike picker. The list
// excludes bikes already held by an overlapping booking and bikes in an
// unavailability window during the session.
func SuitableBikesForSession(
	ctx context.Context,
	scope *tenant.Scope,
	sessionID domain.SessionID,
	studentID domain.UserID,
) ([]SuitableBikeRow, error) {
	sess, err := loadSession(ctx, scope, sessionID)
	if err != nil {
		return nil, err
	}

	transmissionPref := ""
	if studentID != "" {
		stu, err := loadStudent(ctx, scope, studentID)
		if err != nil && !errors.Is(err, ErrStudentNotFound) {
			return nil, err
		}
		if stu != nil {
			transmissionPref = stu.transmissionPref
		}
	}

	cands, err := findSuitableFreeBikes(ctx, scope, sess, transmissionPref)
	if err != nil {
		return nil, err
	}
	if len(cands) == 0 {
		return nil, nil
	}

	// Hydrate the candidate id+location with the human fields the UI needs.
	// One query for the whole set.
	ids := make([]string, 0, len(cands))
	for _, c := range cands {
		ids = append(ids, string(c.id))
	}
	placeholders := ""
	args := []any{string(scope.SchoolID()), string(sess.locationID)}
	for i, id := range ids {
		if i > 0 {
			placeholders += ","
		}
		placeholders += "?"
		args = append(args, id)
	}
	q := fmt.Sprintf(`
		SELECT b.id, COALESCE(b.nickname, ''), COALESCE(b.registration, ''),
		       b.category, b.transmission, COALESCE(b.engine_cc, 0),
		       b.current_location_id, COALESCE(l.name, ''),
		       CASE WHEN b.current_location_id = ? THEN 0 ELSE 1 END AS cross_site
		FROM bikes b
		LEFT JOIN locations l ON l.id = b.current_location_id AND l.school_id = b.school_id
		WHERE b.school_id = ? AND b.id IN (%s)
		ORDER BY cross_site ASC, b.nickname ASC, b.id ASC
	`, placeholders)
	// Re-order args to match: cross_site comparison comes first now.
	args = []any{string(sess.locationID), string(scope.SchoolID())}
	for _, id := range ids {
		args = append(args, id)
	}

	rows, err := scope.Conn().QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("query bike details: %w", err)
	}
	defer rows.Close()

	var out []SuitableBikeRow
	for rows.Next() {
		var (
			r            SuitableBikeRow
			crossSiteInt int
		)
		if err := rows.Scan(
			&r.BikeID, &r.Nickname, &r.Registration,
			&r.Category, &r.Transmission, &r.EngineCC,
			&r.CurrentLocationID, &r.CurrentLocationName,
			&crossSiteInt,
		); err != nil {
			return nil, err
		}
		r.IsCrossSite = crossSiteInt == 1
		out = append(out, r)
	}
	return out, rows.Err()
}
