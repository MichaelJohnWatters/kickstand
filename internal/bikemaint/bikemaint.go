// Package bikemaint is the bike maintenance log — every quid spent
// keeping a bike on the road. Sibling to internal/expenses (which
// covers instructor reimbursements) but with a different audience and
// no approval workflow: admin/owner records, that's the whole flow.
//
// Each record carries a receipt blob. The HTTP layer runs the upload
// through media.ProcessReceipt before calling Record — see
// httpapi/bike_expenses_handlers.go — so this package never sees raw
// bytes, just the storage key + the inline thumb.
package bikemaint

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

// Category is the constrained set of expense kinds we currently
// surface in the UI. Free-form on the DB side, but the HTTP layer
// rejects anything else so screens can hard-code their icons and
// translations.
type Category string

const (
	CategoryParts   Category = "parts"
	CategoryLabour  Category = "labour"
	CategoryMOT     Category = "mot"
	CategoryTax     Category = "tax"
	CategoryService Category = "service"
	CategoryOther   Category = "other"
)

func ValidCategory(c Category) bool {
	switch c {
	case CategoryParts, CategoryLabour, CategoryMOT, CategoryTax, CategoryService, CategoryOther:
		return true
	}
	return false
}

type Expense struct {
	ID                 domain.ExpenseID
	BikeID             domain.BikeID
	Category           Category
	AmountPence        int
	OccurredAt         string // YYYY-MM-DD
	Vendor             string
	Notes              string
	ReceiptStorageKey  string
	ReceiptContentType string
	ReceiptSizeBytes   int
	ReceiptThumb       []byte
	RecordedBy         domain.UserID
	RecordedByName     string
	RecordedAt         time.Time
}

type RecordRequest struct {
	BikeID             domain.BikeID
	Category           Category
	AmountPence        int
	OccurredAt         string // YYYY-MM-DD; defaults to today when blank
	Vendor             string
	Notes              string
	ReceiptStorageKey  string
	ReceiptContentType string
	ReceiptSizeBytes   int
	ReceiptThumb       []byte
	RecordedBy         domain.UserID
}

var (
	ErrNotFound        = errors.New("bikemaint: not found")
	ErrInvalidCategory = errors.New("bikemaint: invalid category")
	ErrAmountRequired  = errors.New("bikemaint: amount must be > 0")
	ErrReceiptRequired = errors.New("bikemaint: receipt required")
	ErrBadDate         = errors.New("bikemaint: occurredAt must be YYYY-MM-DD")
)

// Record inserts a maintenance expense for a bike. Receipt bytes are
// already in the filestore by the time we get here — req carries the
// storage key + the inline thumb only.
func Record(ctx context.Context, scope *tenant.Scope, req RecordRequest) (*Expense, error) {
	if !ValidCategory(req.Category) {
		return nil, ErrInvalidCategory
	}
	if req.AmountPence <= 0 {
		return nil, ErrAmountRequired
	}
	if req.ReceiptStorageKey == "" || req.ReceiptSizeBytes <= 0 {
		return nil, ErrReceiptRequired
	}
	if req.OccurredAt == "" {
		req.OccurredAt = time.Now().UTC().Format("2006-01-02")
	} else if _, err := time.Parse("2006-01-02", req.OccurredAt); err != nil {
		return nil, ErrBadDate
	}

	id := domain.ExpenseID(domain.NewID())
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO bike_expenses
		    (id, school_id, bike_id, category, amount_pence,
		     occurred_at, vendor, notes,
		     receipt_storage_key, receipt_content_type, receipt_size_bytes,
		     receipt_thumb, recorded_by, recorded_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, string(id), string(scope.SchoolID()), string(req.BikeID),
		string(req.Category), req.AmountPence,
		req.OccurredAt, nullableString(req.Vendor), nullableString(req.Notes),
		req.ReceiptStorageKey, req.ReceiptContentType, req.ReceiptSizeBytes,
		req.ReceiptThumb, string(req.RecordedBy), now)
	if err != nil {
		return nil, fmt.Errorf("insert bike expense: %w", err)
	}
	return Get(ctx, scope, id)
}

func Get(ctx context.Context, scope *tenant.Scope, id domain.ExpenseID) (*Expense, error) {
	row := scope.Conn().QueryRowContext(ctx, listQuery+` WHERE e.id = ? AND e.school_id = ?`,
		string(id), string(scope.SchoolID()))
	e, err := scanExpense(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return e, err
}

// ListForBike returns every maintenance record for a bike, newest first.
func ListForBike(ctx context.Context, scope *tenant.Scope, bikeID domain.BikeID) ([]Expense, error) {
	rows, err := scope.Conn().QueryContext(ctx, listQuery+`
		WHERE e.school_id = ? AND e.bike_id = ?
		ORDER BY e.occurred_at DESC, e.recorded_at DESC
	`, string(scope.SchoolID()), string(bikeID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Expense{}
	for rows.Next() {
		e, err := scanExpense(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *e)
	}
	return out, rows.Err()
}

// YearToDateTotal is the sum of amount_pence over rows whose
// occurred_at falls within the current calendar year. Used by the
// fleet table's "£XYZ YTD" pill so the manager sees per-bike spend at
// a glance.
func YearToDateTotal(ctx context.Context, scope *tenant.Scope, bikeID domain.BikeID) (int, error) {
	yearStart := time.Now().UTC().Format("2006") + "-01-01"
	var total int
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT COALESCE(SUM(amount_pence), 0) FROM bike_expenses
		WHERE school_id = ? AND bike_id = ? AND occurred_at >= ?
	`, string(scope.SchoolID()), string(bikeID), yearStart).Scan(&total)
	return total, err
}

// YearToDateTotalsForFleet returns a {bike_id → pence} map of YTD spend
// for every bike in the tenant. Single query — used by the fleet list
// payload so we don't N+1 the per-bike total.
func YearToDateTotalsForFleet(ctx context.Context, scope *tenant.Scope) (map[domain.BikeID]int, error) {
	yearStart := time.Now().UTC().Format("2006") + "-01-01"
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT bike_id, COALESCE(SUM(amount_pence), 0)
		FROM bike_expenses
		WHERE school_id = ? AND occurred_at >= ?
		GROUP BY bike_id
	`, string(scope.SchoolID()), yearStart)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[domain.BikeID]int{}
	for rows.Next() {
		var id domain.BikeID
		var total int
		if err := rows.Scan(&id, &total); err != nil {
			return nil, err
		}
		out[id] = total
	}
	return out, rows.Err()
}

// Delete removes a maintenance record. The receipt blob in the
// filestore is the caller's responsibility — the HTTP layer takes care
// of it so this package stays decoupled from the storage backend.
func Delete(ctx context.Context, scope *tenant.Scope, id domain.ExpenseID) error {
	res, err := scope.Conn().ExecContext(ctx,
		`DELETE FROM bike_expenses WHERE id = ? AND school_id = ?`,
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

// listQuery is the shared SELECT body for Get and ListForBike — joins
// in the recorder's name so the UI can render "recorded by Owen" rows
// without a separate fetch.
const listQuery = `
	SELECT e.id, e.bike_id, e.category, e.amount_pence,
	       e.occurred_at, COALESCE(e.vendor, ''), COALESCE(e.notes, ''),
	       e.receipt_storage_key, e.receipt_content_type, e.receipt_size_bytes,
	       e.receipt_thumb, e.recorded_by, COALESCE(u.name, ''), e.recorded_at
	FROM bike_expenses e
	LEFT JOIN users u ON u.id = e.recorded_by AND u.school_id = e.school_id`

func scanExpense(s interface {
	Scan(dest ...any) error
}) (*Expense, error) {
	var e Expense
	var recordedAtStr string
	if err := s.Scan(
		&e.ID, &e.BikeID, &e.Category, &e.AmountPence,
		&e.OccurredAt, &e.Vendor, &e.Notes,
		&e.ReceiptStorageKey, &e.ReceiptContentType, &e.ReceiptSizeBytes,
		&e.ReceiptThumb, &e.RecordedBy, &e.RecordedByName, &recordedAtStr,
	); err != nil {
		return nil, err
	}
	if recordedAtStr != "" {
		e.RecordedAt, _ = time.Parse(time.RFC3339, recordedAtStr)
	}
	return &e, nil
}

func nullableString(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}
