package admin

import (
	"context"
	"database/sql"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

// gpsProximityKm caps how far a reported fix can plausibly be from
// any of the school's geocoded sites before we treat it as obviously
// bad client data (truncated payload, swapped lat/lng, "0,0" Atlantic
// pin, etc.). Generous enough to cover a long lesson route around NI
// (~150 km radius from Belfast covers everywhere) while still
// catching the obvious garbage.
const gpsProximityKm = 200

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

// UpdateBikeGPS writes a fresh fix to the bike snapshot AND appends a
// row to bike_gps_fixes so the breadcrumb-trail view has history.
// Provider-agnostic — schools wire whatever tracker they have to this
// endpoint. The scheduling/logistics engine does not read these
// columns; they only feed the live-map view.
//
// Both writes happen in one tx so a partial failure can't leave the
// snapshot ahead of the history (or vice versa).
func UpdateBikeGPS(ctx context.Context, scope *tenant.Scope, id domain.BikeID, req UpdateBikeGPSRequest) error {
	if req.Lat < -90 || req.Lat > 90 {
		return fmt.Errorf("%w: lat must be between -90 and 90", ErrInvalidInput)
	}
	if req.Lng < -180 || req.Lng > 180 {
		return fmt.Errorf("%w: lng must be between -180 and 180", ErrInvalidInput)
	}
	// Proximity check: a fix must land within gpsProximityKm of at
	// least one geocoded school site. Skipped when no site carries
	// coords yet (graceful degrade — same outcome as v1, where the
	// risks doc accepted "warn not reject").
	near, err := nearAnySchoolLocation(ctx, scope, req.Lat, req.Lng)
	if err != nil {
		return fmt.Errorf("update bike gps: proximity check: %w", err)
	}
	if !near {
		return fmt.Errorf("%w: fix is more than %d km from every school site",
			ErrInvalidInput, gpsProximityKm)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		res, err := tx.Conn().ExecContext(ctx, `
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
		if _, err := tx.Conn().ExecContext(ctx, `
			INSERT INTO bike_gps_fixes (id, school_id, bike_id, at, lat, lng)
			VALUES (?, ?, ?, ?, ?, ?)
		`, domain.NewID(), string(scope.SchoolID()), string(id), now, req.Lat, req.Lng); err != nil {
			return fmt.Errorf("update bike gps: insert fix: %w", err)
		}
		return nil
	})
}

// GPSFix is a single historical position from bike_gps_fixes.
type GPSFix struct {
	At  string  // RFC3339 UTC
	Lat float64
	Lng float64
}

// ListBikeGPSHistory returns recent fixes for one bike in descending
// time order. `since` is an optional lower bound (RFC3339); empty
// means "no lower bound". `limit` is capped at 500 so a chatty
// tracker can't blow the response size.
func ListBikeGPSHistory(ctx context.Context, scope *tenant.Scope, id domain.BikeID, since string, limit int) ([]GPSFix, error) {
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	where := "school_id = ? AND bike_id = ?"
	args := []any{string(scope.SchoolID()), string(id)}
	if since != "" {
		where += " AND at >= ?"
		args = append(args, since)
	}
	args = append(args, limit)
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT at, lat, lng
		FROM bike_gps_fixes
		WHERE `+where+`
		ORDER BY at DESC
		LIMIT ?
	`, args...)
	if err != nil {
		return nil, fmt.Errorf("list bike gps history: %w", err)
	}
	defer rows.Close()
	var out []GPSFix
	for rows.Next() {
		var f GPSFix
		if err := rows.Scan(&f.At, &f.Lat, &f.Lng); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
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

// nearAnySchoolLocation returns true when the (lat, lng) sits within
// `gpsProximityKm` of at least one location row that has both coords
// set. Returns true when no locations carry coords yet — the check
// is opt-in per school, not a hard gate.
func nearAnySchoolLocation(ctx context.Context, scope *tenant.Scope, lat, lng float64) (bool, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT lat, lng
		FROM locations
		WHERE school_id = ? AND lat IS NOT NULL AND lng IS NOT NULL
	`, string(scope.SchoolID()))
	if err != nil {
		return false, err
	}
	defer rows.Close()
	any := false
	for rows.Next() {
		any = true
		var siteLat, siteLng float64
		if err := rows.Scan(&siteLat, &siteLng); err != nil {
			return false, err
		}
		if haversineKm(lat, lng, siteLat, siteLng) <= gpsProximityKm {
			return true, nil
		}
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	// No geocoded sites → no constraint. Honest, and matches v1
	// behaviour for schools that haven't filled in coords yet.
	if !any {
		return true, nil
	}
	return false, nil
}

// haversineKm returns the great-circle distance in kilometres between
// two WGS-84 points. Standard haversine formula — good to a few metres
// at the scales we care about.
func haversineKm(lat1, lng1, lat2, lng2 float64) float64 {
	const r = 6371.0 // mean Earth radius, km
	toRad := func(d float64) float64 { return d * math.Pi / 180 }
	dLat := toRad(lat2 - lat1)
	dLng := toRad(lng2 - lng1)
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(toRad(lat1))*math.Cos(toRad(lat2))*
			math.Sin(dLng/2)*math.Sin(dLng/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
	return r * c
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
