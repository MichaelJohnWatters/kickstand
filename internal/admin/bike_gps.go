package admin

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// BikeGPSRow is what the manager-facing /admin/bikes/gps endpoint
// returns per bike. Coordinates and timestamp are nullable because
// many schools have no trackers — the UI plots the rest off-map.
type BikeGPSRow struct {
	ID                  domain.BikeID
	Nickname            string
	Registration        string
	Status              domain.BikeStatus // ready / offline / in_use (DB-level)
	LiveStatus          string            // available / offline / in_session / needs_attention (derived)
	CurrentLocationID   domain.LocationID
	CurrentLocationName string
	Lat                 *float64
	Lng                 *float64
	LastSeenAt          string // RFC3339; empty when no fix yet
}

// UpdateBikeGPSRequest is the body shape for POST /bikes/{id}/gps.
type UpdateBikeGPSRequest struct {
	Lat float64
	Lng float64
}

// UpdateBikeGPS writes a fresh fix to the bike snapshot. Provider-
// agnostic — schools wire whatever tracker they have to this endpoint.
// The scheduling/logistics engine does not read these columns; they
// only feed the live-map view.
func UpdateBikeGPS(ctx context.Context, scope *tenant.Scope, id domain.BikeID, req UpdateBikeGPSRequest) error {
	if req.Lat < -90 || req.Lat > 90 {
		return fmt.Errorf("%w: lat must be between -90 and 90", ErrInvalidInput)
	}
	if req.Lng < -180 || req.Lng > 180 {
		return fmt.Errorf("%w: lng must be between -180 and 180", ErrInvalidInput)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE bikes
		SET last_known_lat = ?, last_known_lng = ?, last_known_at = ?
		WHERE id = ? AND school_id = ?
	`, req.Lat, req.Lng, now, string(id), string(scope.SchoolID()))
	if err != nil {
		return fmt.Errorf("update bike gps: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// ListBikeGPS returns every bike in the school with its current GPS
// snapshot plus a derived `LiveStatus` for marker colouring. Bikes
// currently teaching a session resolve to `in_session`; offline DB
// rows surface as `offline`; everything else is `available` unless a
// data inconsistency makes it `needs_attention` (treated as a separate
// bucket so it shows up rather than masquerading as green).
func ListBikeGPS(ctx context.Context, scope *tenant.Scope) ([]BikeGPSRow, error) {
	now := time.Now().UTC().Format(time.RFC3339)
	q := `
		SELECT
			b.id,
			COALESCE(b.nickname, ''),
			COALESCE(b.registration, ''),
			b.status,
			b.current_location_id,
			COALESCE(cl.name, ''),
			b.last_known_lat,
			b.last_known_lng,
			COALESCE(b.last_known_at, ''),
			EXISTS(
				SELECT 1
				FROM bookings bk
				JOIN sessions s ON s.id = bk.session_id AND s.school_id = bk.school_id
				WHERE bk.bike_id = b.id
				  AND bk.school_id = b.school_id
				  AND bk.status NOT IN ('cancelled', 'no_show')
				  AND s.status != 'cancelled'
				  AND s.starts_at <= ?
				  AND s.ends_at > ?
			) AS in_session
		FROM bikes b
		LEFT JOIN locations cl ON cl.id = b.current_location_id AND cl.school_id = b.school_id
		WHERE b.school_id = ?
		ORDER BY b.nickname, b.id
	`
	rows, err := scope.Conn().QueryContext(ctx, q, now, now, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BikeGPSRow
	for rows.Next() {
		var r BikeGPSRow
		var lat, lng sql.NullFloat64
		var inSession bool
		if err := rows.Scan(
			&r.ID, &r.Nickname, &r.Registration, &r.Status,
			&r.CurrentLocationID, &r.CurrentLocationName,
			&lat, &lng, &r.LastSeenAt, &inSession,
		); err != nil {
			return nil, err
		}
		if lat.Valid {
			v := lat.Float64
			r.Lat = &v
		}
		if lng.Valid {
			v := lng.Float64
			r.Lng = &v
		}
		r.LiveStatus = deriveLiveStatus(r.Status, inSession)
		out = append(out, r)
	}
	return out, rows.Err()
}

// deriveLiveStatus collapses the DB `status` enum + a runtime
// "currently in a session" check into the four buckets the map
// markers colour by. Kept pure so it's trivially testable.
func deriveLiveStatus(dbStatus domain.BikeStatus, inSession bool) string {
	switch strings.ToLower(string(dbStatus)) {
	case "offline":
		return "offline"
	case "in_use":
		// DB says in_use but no live session — stale; flag it.
		if !inSession {
			return "needs_attention"
		}
		return "in_session"
	default: // "ready"
		if inSession {
			return "in_session"
		}
		return "available"
	}
}
