package admin

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
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
	// Chunk 2 fields — MOT/tax/mileage tracking.
	MOTExpiresOn        string // YYYY-MM-DD; empty when unknown
	TaxExpiresOn        string // YYYY-MM-DD; empty when unknown
	CurrentMileageMiles int    // 0 when unknown
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

// bikeSelectCols is the SELECT-list shared by GetBike and ListBikes.
// Update both scanners together when fields are added.
const bikeSelectCols = `b.id, COALESCE(b.nickname,''), COALESCE(b.make,''), COALESCE(b.model,''),
	COALESCE(b.registration,''), b.category, b.transmission, COALESCE(b.engine_cc, 0),
	b.status, b.home_location_id, COALESCE(hl.name, ''),
	b.current_location_id, COALESCE(cl.name, ''),
	COALESCE(b.mot_expires_on, ''), COALESCE(b.tax_expires_on, ''),
	COALESCE(b.current_mileage_miles, 0)`

func scanBike(scanner interface {
	Scan(dest ...any) error
}) (*BikeRow, error) {
	var b BikeRow
	if err := scanner.Scan(
		&b.ID, &b.Nickname, &b.Make, &b.Model, &b.Registration,
		&b.Category, &b.Transmission, &b.EngineCC, &b.Status,
		&b.HomeLocationID, &b.HomeLocationName,
		&b.CurrentLocationID, &b.CurrentLocationName,
		&b.MOTExpiresOn, &b.TaxExpiresOn, &b.CurrentMileageMiles,
	); err != nil {
		return nil, err
	}
	b.IsCrossSite = b.HomeLocationID != b.CurrentLocationID
	return &b, nil
}

func GetBike(ctx context.Context, scope *tenant.Scope, id domain.BikeID) (*BikeRow, error) {
	q := `
		SELECT ` + bikeSelectCols + `
		FROM bikes b
		LEFT JOIN locations hl ON hl.id = b.home_location_id AND hl.school_id = b.school_id
		LEFT JOIN locations cl ON cl.id = b.current_location_id AND cl.school_id = b.school_id
		WHERE b.id = ? AND b.school_id = ?
	`
	row := scope.Conn().QueryRowContext(ctx, q, string(id), string(scope.SchoolID()))
	b, err := scanBike(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return b, err
}

func ListBikes(ctx context.Context, scope *tenant.Scope) ([]BikeRow, error) {
	q := `
		SELECT ` + bikeSelectCols + `
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
		b, err := scanBike(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *b)
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
	// Pointer fields so "" can mean "clear it" (set NULL) while nil
	// means "leave unchanged". The HTTP handler converts JSON nulls /
	// missing keys → nil.
	MOTExpiresOn *string
	TaxExpiresOn *string
}

func UpdateBike(ctx context.Context, scope *tenant.Scope, id domain.BikeID, req UpdateBikeRequest) error {
	if req.HomeLocationID != "" {
		if err := requireLocation(ctx, scope, req.HomeLocationID); err != nil {
			return err
		}
	}
	// Validate ISO date format before we touch the DB.
	if req.MOTExpiresOn != nil && *req.MOTExpiresOn != "" {
		if _, _, err := ParseExpiry(*req.MOTExpiresOn); err != nil {
			return fmt.Errorf("%w: motExpiresOn must be YYYY-MM-DD", ErrInvalidInput)
		}
	}
	if req.TaxExpiresOn != nil && *req.TaxExpiresOn != "" {
		if _, _, err := ParseExpiry(*req.TaxExpiresOn); err != nil {
			return fmt.Errorf("%w: taxExpiresOn must be YYYY-MM-DD", ErrInvalidInput)
		}
	}

	// Build a dynamic SET. The existing baseline fields always update;
	// MOT/tax follow the pointer-fields convention.
	parts := []string{
		"nickname = ?", "make = ?", "model = ?", "registration = ?",
		"engine_cc = ?",
		"home_location_id = COALESCE(NULLIF(?, ''), home_location_id)",
	}
	args := []any{
		req.Nickname, req.Make, req.Model, req.Registration, req.EngineCC,
		string(req.HomeLocationID),
	}
	if req.MOTExpiresOn != nil {
		parts = append(parts, "mot_expires_on = NULLIF(?, '')")
		args = append(args, *req.MOTExpiresOn)
	}
	if req.TaxExpiresOn != nil {
		parts = append(parts, "tax_expires_on = NULLIF(?, '')")
		args = append(args, *req.TaxExpiresOn)
	}
	q := fmt.Sprintf("UPDATE bikes SET %s WHERE id = ? AND school_id = ?",
		strings.Join(parts, ", "))
	args = append(args, string(id), string(scope.SchoolID()))
	res, err := scope.Conn().ExecContext(ctx, q, args...)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// RecordMileageRequest is one mileage reading for a bike. Source is
// free-form (`manual`, `mot`, `service`, `incident`) — we don't
// constrain at the schema level so future capture flows can add new
// kinds without a migration.
type RecordMileageRequest struct {
	Miles      int
	Source     string
	RecordedBy domain.UserID
}

// RecordMileage appends to the mileage log and updates the
// current_mileage_miles snapshot on the bike row. Wrapped in a
// transaction so the snapshot never gets out of sync with the log.
func RecordMileage(ctx context.Context, scope *tenant.Scope, id domain.BikeID, req RecordMileageRequest) error {
	if req.Miles < 0 {
		return fmt.Errorf("%w: miles must be >= 0", ErrInvalidInput)
	}
	source := strings.TrimSpace(req.Source)
	if source == "" {
		source = "manual"
	}
	now := time.Now().UTC().Format(time.RFC3339)
	return scope.WithTx(ctx, func(tx *tenant.Scope) error {
		res, err := tx.Conn().ExecContext(ctx, `
			UPDATE bikes SET current_mileage_miles = ?
			WHERE id = ? AND school_id = ?
		`, req.Miles, string(id), string(scope.SchoolID()))
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return ErrNotFound
		}
		_, err = tx.Conn().ExecContext(ctx, `
			INSERT INTO bike_mileage_log
			    (id, school_id, bike_id, miles, source, recorded_by, recorded_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)
		`, domain.NewID(), string(scope.SchoolID()), string(id),
			req.Miles, source, string(req.RecordedBy), now)
		return err
	})
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

