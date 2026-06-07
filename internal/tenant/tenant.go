// Package tenant is the multi-tenant isolation seam.
//
// Every data-access call takes a *Scope, which bundles a DB/Tx handle with the
// caller's authoritative school_id. The discipline is simple:
//
//   - Data-access functions take *Scope as their first parameter (after ctx).
//   - Inside the function, the WHERE clause MUST include `school_id = ?` bound
//     to scope.SchoolID(). Forgetting it is a code-review check (and an
//     integration-test target).
//
// Why this matters: SQLite has no Row-Level Security. When we move to
// Postgres+Supabase, RLS will enforce this at the DB layer; until then, the
// scope-required-everywhere pattern is what stops one school's data leaking
// into another's response. Keep the guarantee in one place; never resolve
// SchoolID from globals or request context inside data-access.
package tenant

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/michaeljohnwatters/kickstand/internal/domain"
)

// DBTX is the intersection of *sql.DB and *sql.Tx — all the methods we need
// for normal query execution. Lets data-access code work transparently inside
// or outside a transaction.
type DBTX interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// Scope is "a DB handle, school-scoped." Construct one once per request after
// auth has resolved who the caller is.
type Scope struct {
	conn     DBTX
	schoolID domain.SchoolID
}

// NewScope wraps a DB/Tx with a required school_id. Panics on empty ID —
// callers must have already resolved tenancy.
func NewScope(conn DBTX, schoolID domain.SchoolID) *Scope {
	if schoolID == "" {
		panic("tenant.NewScope: empty SchoolID — callers must resolve tenancy before scoping")
	}
	if conn == nil {
		panic("tenant.NewScope: nil DBTX")
	}
	return &Scope{conn: conn, schoolID: schoolID}
}

// SchoolID returns the bound school id. Use this in every WHERE clause.
func (s *Scope) SchoolID() domain.SchoolID { return s.schoolID }

// Conn returns the wrapped DB/Tx handle.
func (s *Scope) Conn() DBTX { return s.conn }

// WithTx runs fn inside a write transaction. With the DB opened via
// db.Open (which sets _txlock=immediate) every BeginTx issues
// BEGIN IMMEDIATE, acquiring the write lock at the start — this is what
// stops two concurrent booking attempts from both reading "0 bookings"
// and racing to insert. busy_timeout serialises them cleanly.
//
// The caller's fn receives a tx-scoped *Scope with the same school_id. If fn
// returns an error the tx is rolled back; nil commits.
func (s *Scope) WithTx(ctx context.Context, fn func(*Scope) error) error {
	db, ok := s.conn.(*sql.DB)
	if !ok {
		return fmt.Errorf("tenant: WithTx called on a non-DB scope (already inside a tx)")
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	txScope := &Scope{conn: tx, schoolID: s.schoolID}
	if err := fn(txScope); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}
