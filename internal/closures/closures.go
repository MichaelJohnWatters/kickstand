// Package closures manages school-wide closed dates.
//
// The reads are tiny, the writes are infrequent. IsClosed is the one
// hot path — called from session create + template materialise — so
// it lives behind a single indexed BETWEEN query.
//
// We don't auto-cancel sessions on a newly-created closure. The
// manager gets a count of "sessions on closed dates" in the UI and
// uses the bulk-cancel action to clear them. Auto-cancel-cascading
// would surprise the student side without warning.
package closures

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
	ErrNotFound     = errors.New("closures: not found")
	ErrInvalidInput = errors.New("closures: invalid input")
)

type Closure struct {
	ID         string
	FromDate   string // YYYY-MM-DD
	ToDate     string // YYYY-MM-DD
	Label      string
	Reason     string
	CreatedAt  time.Time
	CreatedBy  domain.UserID
	// SessionsAffected is populated by List for the UI's "this closure
	// has 3 sessions on it" warning. Zero on Create/Get.
	SessionsAffected int
}

type CreateRequest struct {
	FromDate  string
	ToDate    string
	Label     string
	Reason    string
	CreatedBy domain.UserID
}

func Create(ctx context.Context, scope *tenant.Scope, req CreateRequest) (*Closure, error) {
	if err := validate(req); err != nil {
		return nil, err
	}
	id := domain.NewID()
	at := time.Now().UTC().Format(time.RFC3339)
	_, err := scope.Conn().ExecContext(ctx, `
		INSERT INTO school_closures
		    (id, school_id, from_date, to_date, label, reason, created_at, created_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`, id, string(scope.SchoolID()), req.FromDate, req.ToDate,
		req.Label, req.Reason, at, string(req.CreatedBy))
	if err != nil {
		return nil, fmt.Errorf("insert closure: %w", err)
	}
	return Get(ctx, scope, id)
}

func Get(ctx context.Context, scope *tenant.Scope, id string) (*Closure, error) {
	var c Closure
	var atStr string
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT id, from_date, to_date, label, reason, created_at, created_by
		FROM school_closures
		WHERE id = ? AND school_id = ?
	`, id, string(scope.SchoolID())).Scan(
		&c.ID, &c.FromDate, &c.ToDate, &c.Label, &c.Reason, &atStr, &c.CreatedBy,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	c.CreatedAt, _ = time.Parse(time.RFC3339, atStr)
	return &c, nil
}

func Delete(ctx context.Context, scope *tenant.Scope, id string) error {
	res, err := scope.Conn().ExecContext(ctx,
		`DELETE FROM school_closures WHERE id = ? AND school_id = ?`,
		id, string(scope.SchoolID()))
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// List returns closures ordered by from_date ASC, plus the number of
// existing sessions that fall inside each one — surfaced in the UI so
// the manager can see how much follow-up the closure implies.
func List(ctx context.Context, scope *tenant.Scope) ([]Closure, error) {
	rows, err := scope.Conn().QueryContext(ctx, `
		SELECT c.id, c.from_date, c.to_date, c.label, c.reason,
		       c.created_at, c.created_by,
		       (SELECT COUNT(*) FROM sessions s
		         WHERE s.school_id = c.school_id
		           AND substr(s.starts_at, 1, 10) BETWEEN c.from_date AND c.to_date
		           AND s.status = 'scheduled') AS sessions_affected
		FROM school_closures c
		WHERE c.school_id = ?
		ORDER BY c.from_date ASC, c.id ASC
	`, string(scope.SchoolID()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Closure
	for rows.Next() {
		var c Closure
		var atStr string
		if err := rows.Scan(
			&c.ID, &c.FromDate, &c.ToDate, &c.Label, &c.Reason,
			&atStr, &c.CreatedBy, &c.SessionsAffected,
		); err != nil {
			return nil, err
		}
		c.CreatedAt, _ = time.Parse(time.RFC3339, atStr)
		out = append(out, c)
	}
	return out, rows.Err()
}

// IsClosed returns whether `date` (YYYY-MM-DD) sits inside any open
// closure for this school. Indexed point query — safe to call from
// hot paths like session-create.
func IsClosed(ctx context.Context, scope *tenant.Scope, date string) (bool, error) {
	var n int
	err := scope.Conn().QueryRowContext(ctx, `
		SELECT COUNT(*) FROM school_closures
		WHERE school_id = ?
		  AND from_date <= ? AND to_date >= ?
	`, string(scope.SchoolID()), date, date).Scan(&n)
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

func validate(r CreateRequest) error {
	if r.Label == "" {
		return fmt.Errorf("%w: label required", ErrInvalidInput)
	}
	if _, err := time.Parse("2006-01-02", r.FromDate); err != nil {
		return fmt.Errorf("%w: fromDate must be YYYY-MM-DD", ErrInvalidInput)
	}
	if _, err := time.Parse("2006-01-02", r.ToDate); err != nil {
		return fmt.Errorf("%w: toDate must be YYYY-MM-DD", ErrInvalidInput)
	}
	if r.FromDate > r.ToDate {
		return fmt.Errorf("%w: fromDate must be on or before toDate", ErrInvalidInput)
	}
	if r.CreatedBy == "" {
		return fmt.Errorf("%w: createdBy required", ErrInvalidInput)
	}
	return nil
}
