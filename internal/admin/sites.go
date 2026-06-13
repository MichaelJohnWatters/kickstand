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

// ----- Locations -----

type Location struct {
	ID        domain.LocationID
	Name      string
	Address   string
	Image     []byte // inline header JPEG (~300×120); empty when none seeded
	Lat       *float64 // optional WGS-84 coords; drives proximity check + map jump-to
	Lng       *float64
	CreatedAt time.Time
}

type CreateLocationRequest struct {
	Name    string
	Address string
}

func CreateLocation(ctx context.Context, scope *tenant.Scope, req CreateLocationRequest) (*Location, error) {
	if strings.TrimSpace(req.Name) == "" {
		return nil, fmt.Errorf("%w: name required", ErrInvalidInput)
	}
	loc := &Location{
		ID:        domain.LocationID(domain.NewID()),
		Name:      req.Name,
		Address:   req.Address,
		CreatedAt: time.Now().UTC(),
	}
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO locations (id, school_id, name, address, created_at)
		VALUES (?, ?, ?, ?, ?)
	`, string(loc.ID), string(scope.SchoolID()), loc.Name, loc.Address, loc.CreatedAt.Format(time.RFC3339))
	if err != nil {
		return nil, fmt.Errorf("insert location: %w", err)
	}
	return loc, nil
}

func ListLocations(ctx context.Context, scope *tenant.Scope) ([]Location, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT id, name, COALESCE(address, ''), image, lat, lng, created_at
		FROM locations WHERE school_id = ? ORDER BY name ASC
	`, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Location
	for rows.Next() {
		var l Location
		var createdStr string
		var lat, lng sql.NullFloat64
		if err := rows.Scan(&l.ID, &l.Name, &l.Address, &l.Image, &lat, &lng, &createdStr); err != nil {
			return nil, err
		}
		if lat.Valid {
			v := lat.Float64
			l.Lat = &v
		}
		if lng.Valid {
			v := lng.Float64
			l.Lng = &v
		}
		l.CreatedAt, _ = time.Parse(time.RFC3339, createdStr)
		out = append(out, l)
	}
	return out, rows.Err()
}

type UpdateLocationRequest struct {
	Name    string
	Address string
}

func UpdateLocation(ctx context.Context, scope *tenant.Scope, id domain.LocationID, req UpdateLocationRequest) error {
	if strings.TrimSpace(req.Name) == "" {
		return fmt.Errorf("%w: name required", ErrInvalidInput)
	}
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE locations SET name = ?, address = ?
		WHERE id = ? AND school_id = ?
	`, req.Name, req.Address, string(id), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteLocation refuses if the location is in use anywhere — we keep an
// audit trail rather than cascade-deleting. Admins should mark sessions
// elsewhere first.
func DeleteLocation(ctx context.Context, scope *tenant.Scope, id domain.LocationID) error {
	if used, err := locationInUse(ctx, scope, id); err != nil {
		return err
	} else if used {
		return ErrCannotDeleteUsed
	}
	res, err := scope.Conn().ExecContext(ctx,
		`DELETE FROM locations WHERE id = ? AND school_id = ?`,
		string(id), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func locationInUse(ctx context.Context, scope *tenant.Scope, id domain.LocationID) (bool, error) {
	// Check sessions, bikes (home + current), travel_times, instructor_profiles.
	var n int
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT
		    (SELECT COUNT(*) FROM sessions WHERE school_id = ? AND location_id = ?) +
		    (SELECT COUNT(*) FROM bikes    WHERE school_id = ? AND (home_location_id = ? OR current_location_id = ?)) +
		    (SELECT COUNT(*) FROM travel_times WHERE school_id = ? AND (from_location_id = ? OR to_location_id = ?)) +
		    (SELECT COUNT(*) FROM instructor_profiles WHERE school_id = ? AND home_location_id = ?)
	`, string(scope.SchoolID()), string(id),
		string(scope.SchoolID()), string(id), string(id),
		string(scope.SchoolID()), string(id), string(id),
		string(scope.SchoolID()), string(id),
	).Scan(&n)
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// ----- Travel-time matrix -----

type TravelTime struct {
	FromLocationID domain.LocationID
	ToLocationID   domain.LocationID
	Minutes        int
}

func ListTravelTimes(ctx context.Context, scope *tenant.Scope) ([]TravelTime, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT from_location_id, to_location_id, minutes
		FROM travel_times WHERE school_id = ?
		ORDER BY from_location_id ASC, to_location_id ASC
	`, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TravelTime
	for rows.Next() {
		var t TravelTime
		if err := rows.Scan(&t.FromLocationID, &t.ToLocationID, &t.Minutes); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// SetTravelTime upserts a single (from, to) pair. Symmetric pairs are NOT
// auto-created — schools may have one-way differences (e.g. rush-hour).
func SetTravelTime(ctx context.Context, scope *tenant.Scope, t TravelTime) error {
	if t.FromLocationID == t.ToLocationID {
		return fmt.Errorf("%w: from and to must differ", ErrInvalidInput)
	}
	if t.Minutes < 0 {
		return fmt.Errorf("%w: minutes must be non-negative", ErrInvalidInput)
	}
	// Try insert; on conflict update.
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO travel_times (school_id, from_location_id, to_location_id, minutes)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(school_id, from_location_id, to_location_id) DO UPDATE SET minutes = excluded.minutes
	`, string(scope.SchoolID()), string(t.FromLocationID), string(t.ToLocationID), t.Minutes)
	if err != nil {
		return fmt.Errorf("upsert travel time: %w", err)
	}
	return nil
}

func DeleteTravelTime(ctx context.Context, scope *tenant.Scope, from, to domain.LocationID) error {
	res, err := scope.Conn().ExecContext(ctx,
		`DELETE FROM travel_times WHERE school_id = ? AND from_location_id = ? AND to_location_id = ?`,
		string(scope.SchoolID()), string(from), string(to))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

