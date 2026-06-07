// Package logistics produces the end-of-day "bikes to move" view from
// plan §5.
//
// It's a derived query, not stored data: compare assigned bikes' current
// locations against the next day's session locations, grouped by
// destination. The output drives the admin "Bike logistics" screen.
package logistics

import (
	"context"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// Move describes one bike that needs to be relocated for a session.
type Move struct {
	BikeID               domain.BikeID
	BikeNickname         string
	BikeCategory         domain.LicenceCategory
	BikeRegistration     string
	FromLocationID       domain.LocationID
	FromLocationName     string
	ToLocationID         domain.LocationID
	ToLocationName       string
	SessionID            domain.SessionID
	SessionStartsAt      time.Time
	CourseTypeName       string
	StudentID            domain.UserID
	StudentName          string
	BookingID            domain.BookingID
}

// Destination groups moves by where the bikes need to end up. The UI
// renders these as "Lisburn needs: bike A, bike C" cards.
type Destination struct {
	LocationID   domain.LocationID
	LocationName string
	Moves        []Move
}

// Summary is the response payload.
type Summary struct {
	Date         string // YYYY-MM-DD
	Destinations []Destination
	TotalMoves   int
}

// SummaryForDay returns the moves required for sessions on the given
// calendar date (interpreted as UTC for simplicity — schools running across
// a DST boundary are pathological cases).
//
// Logic: for each non-cancelled booking on a session that starts on `date`,
// where the assigned bike's current_location_id ≠ session.location_id, we
// emit a Move. Cancelled bookings and sessions without an assigned bike
// (which shouldn't happen after a successful Book) are skipped.
func SummaryForDay(ctx context.Context, scope *tenant.Scope, date time.Time) (*Summary, error) {
	dayStart := time.Date(date.Year(), date.Month(), date.Day(), 0, 0, 0, 0, time.UTC)
	dayEnd := dayStart.Add(24 * time.Hour)

	const q = `
		SELECT b.bike_id, COALESCE(bk.nickname, ''), bk.category, COALESCE(bk.registration, ''),
		       bk.current_location_id, COALESCE(fl.name, ''),
		       s.location_id, COALESCE(tl.name, ''),
		       s.id, s.starts_at, COALESCE(ct.name, ''),
		       b.student_id, COALESCE(u.name, ''), b.id
		FROM bookings b
		JOIN sessions s     ON s.id = b.session_id AND s.school_id = b.school_id
		JOIN bikes bk       ON bk.id = b.bike_id    AND bk.school_id = b.school_id
		JOIN course_types ct ON ct.id = s.course_type_id AND ct.school_id = s.school_id
		LEFT JOIN locations fl ON fl.id = bk.current_location_id AND fl.school_id = b.school_id
		LEFT JOIN locations tl ON tl.id = s.location_id          AND tl.school_id = b.school_id
		LEFT JOIN users u      ON u.id = b.student_id            AND u.school_id = b.school_id
		WHERE b.school_id = ?
		  AND b.status IN ('booked', 'needs_reassignment')
		  AND b.bike_id IS NOT NULL
		  AND bk.current_location_id <> s.location_id
		  AND s.starts_at >= ? AND s.starts_at < ?
		ORDER BY tl.name ASC, s.starts_at ASC
	`
	rows, err := scope.Conn().QueryContext(ctx, q,
		string(scope.SchoolID()),
		dayStart.Format(time.RFC3339),
		dayEnd.Format(time.RFC3339),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// Build destinations as a map by toLocationID, preserving discovery order
	// (which matches the ORDER BY locationName).
	type destBuilder struct {
		dest *Destination
	}
	byLoc := map[domain.LocationID]*destBuilder{}
	order := []domain.LocationID{}

	for rows.Next() {
		var (
			m         Move
			startsStr string
		)
		if err := rows.Scan(
			&m.BikeID, &m.BikeNickname, &m.BikeCategory, &m.BikeRegistration,
			&m.FromLocationID, &m.FromLocationName,
			&m.ToLocationID, &m.ToLocationName,
			&m.SessionID, &startsStr, &m.CourseTypeName,
			&m.StudentID, &m.StudentName, &m.BookingID,
		); err != nil {
			return nil, err
		}
		m.SessionStartsAt, _ = time.Parse(time.RFC3339, startsStr)
		b, ok := byLoc[m.ToLocationID]
		if !ok {
			b = &destBuilder{dest: &Destination{
				LocationID: m.ToLocationID, LocationName: m.ToLocationName,
			}}
			byLoc[m.ToLocationID] = b
			order = append(order, m.ToLocationID)
		}
		b.dest.Moves = append(b.dest.Moves, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	dest := make([]Destination, 0, len(order))
	total := 0
	for _, id := range order {
		d := byLoc[id].dest
		total += len(d.Moves)
		dest = append(dest, *d)
	}
	return &Summary{
		Date:         dayStart.Format("2006-01-02"),
		Destinations: dest,
		TotalMoves:   total,
	}, nil
}
