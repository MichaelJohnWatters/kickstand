package admin

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
	"github.com/michaeljohnwatters/kickstand/internal/tenant"
)

type BikeRow struct {
	ID                  domain.BikeID
	Nickname            string
	Make                string
	Model               string
	Registration        string
	Category            domain.LicenceCategory
	Transmission        domain.Transmission
	EngineCC            int
	Status              domain.BikeStatus
	HomeLocationID      domain.LocationID
	HomeLocationName    string
	CurrentLocationID   domain.LocationID
	CurrentLocationName string
	IsCrossSite         bool // current ≠ home
}

type CreateBikeRequest struct {
	Nickname       string
	Make           string
	Model          string
	Registration   string
	Category       domain.LicenceCategory
	Transmission   domain.Transmission
	EngineCC       int
	HomeLocationID domain.LocationID
}

func CreateBike(ctx context.Context, scope *tenant.Scope, req CreateBikeRequest) (*BikeRow, error) {
	if !validCategory(req.Category) {
		return nil, fmt.Errorf("%w: category must be A1/A2/A", ErrInvalidInput)
	}
	if !validTransmission(req.Transmission) {
		return nil, fmt.Errorf("%w: transmission must be manual/auto", ErrInvalidInput)
	}
	if req.HomeLocationID == "" {
		return nil, fmt.Errorf("%w: homeLocationId required", ErrInvalidInput)
	}
	if err := requireLocation(ctx, scope, req.HomeLocationID); err != nil {
		return nil, err
	}

	id := domain.BikeID(domain.NewID())
	at := time.Now().UTC().Format(time.RFC3339)
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO bikes (id, school_id, nickname, make, model, registration,
		    category, transmission, engine_cc, status,
		    home_location_id, current_location_id, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'ready', ?, ?, ?)
	`, string(id), string(scope.SchoolID()), req.Nickname, req.Make, req.Model, req.Registration,
		string(req.Category), string(req.Transmission), req.EngineCC,
		string(req.HomeLocationID), string(req.HomeLocationID), at)
	if err != nil {
		return nil, fmt.Errorf("insert bike: %w", err)
	}
	return GetBike(ctx, scope, id)
}

func GetBike(ctx context.Context, scope *tenant.Scope, id domain.BikeID) (*BikeRow, error) {
	const q = `
		SELECT b.id, COALESCE(b.nickname,''), COALESCE(b.make,''), COALESCE(b.model,''),
		       COALESCE(b.registration,''), b.category, b.transmission, COALESCE(b.engine_cc, 0),
		       b.status, b.home_location_id, COALESCE(hl.name, ''),
		       b.current_location_id, COALESCE(cl.name, '')
		FROM bikes b
		LEFT JOIN locations hl ON hl.id = b.home_location_id AND hl.school_id = b.school_id
		LEFT JOIN locations cl ON cl.id = b.current_location_id AND cl.school_id = b.school_id
		WHERE b.id = ? AND b.school_id = ?
	`
	var b BikeRow
	err := scope.Conn().QueryRowContext(ctx, q, string(id), string(scope.SchoolID())).Scan(
		&b.ID, &b.Nickname, &b.Make, &b.Model, &b.Registration,
		&b.Category, &b.Transmission, &b.EngineCC, &b.Status,
		&b.HomeLocationID, &b.HomeLocationName,
		&b.CurrentLocationID, &b.CurrentLocationName,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	b.IsCrossSite = b.HomeLocationID != b.CurrentLocationID
	return &b, nil
}

func ListBikes(ctx context.Context, scope *tenant.Scope) ([]BikeRow, error) {
	const q = `
		SELECT b.id, COALESCE(b.nickname,''), COALESCE(b.make,''), COALESCE(b.model,''),
		       COALESCE(b.registration,''), b.category, b.transmission, COALESCE(b.engine_cc, 0),
		       b.status, b.home_location_id, COALESCE(hl.name, ''),
		       b.current_location_id, COALESCE(cl.name, '')
		FROM bikes b
		LEFT JOIN locations hl ON hl.id = b.home_location_id AND hl.school_id = b.school_id
		LEFT JOIN locations cl ON cl.id = b.current_location_id AND cl.school_id = b.school_id
		WHERE b.school_id = ?
		ORDER BY b.category, b.nickname, b.id
	`
	rows, err := scope.Conn().QueryContext(ctx, q, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BikeRow
	for rows.Next() {
		var b BikeRow
		if err := rows.Scan(
			&b.ID, &b.Nickname, &b.Make, &b.Model, &b.Registration,
			&b.Category, &b.Transmission, &b.EngineCC, &b.Status,
			&b.HomeLocationID, &b.HomeLocationName,
			&b.CurrentLocationID, &b.CurrentLocationName,
		); err != nil {
			return nil, err
		}
		b.IsCrossSite = b.HomeLocationID != b.CurrentLocationID
		out = append(out, b)
	}
	return out, rows.Err()
}

type UpdateBikeRequest struct {
	Nickname       string
	Make           string
	Model          string
	Registration   string
	EngineCC       int
	HomeLocationID domain.LocationID
}

func UpdateBike(ctx context.Context, scope *tenant.Scope, id domain.BikeID, req UpdateBikeRequest) error {
	if req.HomeLocationID != "" {
		if err := requireLocation(ctx, scope, req.HomeLocationID); err != nil {
			return err
		}
	}
	res, err := scope.Conn().ExecContext(ctx, `
		UPDATE bikes SET
		    nickname = ?, make = ?, model = ?, registration = ?,
		    engine_cc = ?,
		    home_location_id = COALESCE(NULLIF(?, ''), home_location_id)
		WHERE id = ? AND school_id = ?
	`, req.Nickname, req.Make, req.Model, req.Registration, req.EngineCC,
		string(req.HomeLocationID), string(id), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// RestoreBike flips an offline bike back to 'ready' and clears any
// active unavailability windows that end in the future. Returns ErrNotFound
// if the bike doesn't exist.
func RestoreBike(ctx context.Context, scope *tenant.Scope, id domain.BikeID) error {
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		res, err := tx.Conn().ExecContext(ctx,
			`UPDATE bikes SET status = 'ready' WHERE id = ? AND school_id = ?`,
			string(id), string(scope.SchoolID()))
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return ErrNotFound
		}
		// Close any open-ended unavailability rows from now forward.
		now := time.Now().UTC().Format(time.RFC3339)
		_, err = tx.Conn().ExecContext(ctx, `
			UPDATE bike_unavailability SET ends_at = ?
			WHERE bike_id = ? AND school_id = ? AND ends_at > ?
		`, now, string(id), string(scope.SchoolID()), now)
		return err
	})
}

// MoveBike updates a bike's current location. Used by the logistics screen
// when staff confirms a physical move has happened. Doesn't touch
// home_location_id.
func MoveBike(ctx context.Context, scope *tenant.Scope, id domain.BikeID, newLocationID domain.LocationID) error {
	if newLocationID == "" {
		return fmt.Errorf("%w: locationId required", ErrInvalidInput)
	}
	if err := requireLocation(ctx, scope, newLocationID); err != nil {
		return err
	}
	res, err := scope.Conn().ExecContext(ctx,
		`UPDATE bikes SET current_location_id = ? WHERE id = ? AND school_id = ?`,
		string(newLocationID), string(id), string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteBike refuses if the bike has been used in any booking — booking
// rows must be preserved for the audit trail. Operational data like
// bike_unavailability is cleaned up in the same transaction; it's not an
// audit record.
func DeleteBike(ctx context.Context, scope *tenant.Scope, id domain.BikeID) error {
	var n int
	if err := scope.Conn().QueryRowContext(ctx,
		`SELECT COUNT(*) FROM bookings WHERE school_id = ? AND bike_id = ?`,
		string(scope.SchoolID()), string(id),
	).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return ErrCannotDeleteUsed
	}
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		// Sweep operational rows that reference the bike. Bookings are
		// already guaranteed empty by the check above.
		if _, err := tx.Conn().ExecContext(ctx,
			`DELETE FROM bike_unavailability WHERE school_id = ? AND bike_id = ?`,
			string(scope.SchoolID()), string(id)); err != nil {
			return err
		}
		if _, err := tx.Conn().ExecContext(ctx,
			`DELETE FROM disruptions WHERE school_id = ? AND bike_id = ?`,
			string(scope.SchoolID()), string(id)); err != nil {
			return err
		}
		res, err := tx.Conn().ExecContext(ctx,
			`DELETE FROM bikes WHERE id = ? AND school_id = ?`,
			string(id), string(scope.SchoolID()))
		if err != nil {
			return err
		}
		rows, _ := res.RowsAffected()
		if rows == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// ----- helpers -----

func requireLocation(ctx context.Context, scope *tenant.Scope, id domain.LocationID) error {
	var n int
	err := scope.Conn().QueryRowContext(ctx,
		`SELECT 1 FROM locations WHERE id = ? AND school_id = ?`,
		string(id), string(scope.SchoolID()),
	).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%w: location does not exist", ErrInvalidInput)
	}
	return err
}

func validCategory(c domain.LicenceCategory) bool {
	switch c {
	case domain.CategoryA1, domain.CategoryA2, domain.CategoryA:
		return true
	}
	return false
}

func validTransmission(t domain.Transmission) bool {
	return t == domain.TransmissionManual || t == domain.TransmissionAuto
}

