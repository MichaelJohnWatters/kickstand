// Package db owns the SQLite connection setup and the migrations runner.
//
// The PRAGMAs set in Open enable foreign keys (off by default in SQLite!) and
// WAL mode so concurrent readers don't block the booking transaction.
package db

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"sort"
	"strings"
	"time"

	"github.com/michaeljohnwatters/kickstand/migrations"
	_ "modernc.org/sqlite"
)

// Open returns a *sql.DB ready for use. dsn examples:
//
//	"kickstand.db"
//	":memory:"  (for tests; note: shared by single connection only)
//
// The DSN is augmented with:
//   - _txlock=immediate: every BeginTx issues BEGIN IMMEDIATE, which acquires
//     the write lock at BEGIN. Critical for the booking engine — without this
//     two concurrent read-then-write transactions can both read the same
//     "0 bookings" snapshot and race to insert.
//   - _pragma=foreign_keys(on): SQLite ships with FK enforcement OFF.
//   - _pragma=journal_mode(wal): concurrent readers, single writer.
//   - _pragma=busy_timeout(5000): wait 5s on lock contention instead of
//     failing. Must be set on EVERY connection — that's why we use the DSN
//     param rather than a one-shot PRAGMA after open.
//   - _pragma=synchronous(normal): safe with WAL and much faster than FULL.
func Open(dsn string) (*sql.DB, error) {
	d, err := sql.Open("sqlite", augmentDSN(dsn))
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	return d, nil
}

func augmentDSN(dsn string) string {
	add := []string{
		"_txlock=immediate",
		"_pragma=foreign_keys(on)",
		"_pragma=journal_mode(wal)",
		"_pragma=busy_timeout(5000)",
		"_pragma=synchronous(normal)",
	}
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	return dsn + sep + strings.Join(add, "&")
}

// Migrate applies all *.up.sql files in /migrations in numeric order, tracking
// what's been applied in a schema_migrations table. Idempotent — safe to call
// on every server boot.
func Migrate(ctx context.Context, d *sql.DB) error {
	if _, err := d.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			id          TEXT PRIMARY KEY,
			applied_at  TEXT NOT NULL
		)
	`); err != nil {
		return fmt.Errorf("ensure schema_migrations: %w", err)
	}

	files, err := loadUpMigrations()
	if err != nil {
		return err
	}

	applied, err := loadAppliedSet(ctx, d)
	if err != nil {
		return err
	}

	for _, m := range files {
		if applied[m.id] {
			continue
		}
		if err := applyMigration(ctx, d, m); err != nil {
			return fmt.Errorf("apply %s: %w", m.id, err)
		}
	}
	return nil
}

type migration struct {
	id   string // e.g. "0001_initial"
	body string
}

func loadUpMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		return nil, fmt.Errorf("read migrations dir: %w", err)
	}
	var out []migration
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".up.sql") {
			continue
		}
		body, err := fs.ReadFile(migrations.FS, name)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", name, err)
		}
		out = append(out, migration{
			id:   strings.TrimSuffix(name, ".up.sql"),
			body: string(body),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].id < out[j].id })
	return out, nil
}

func loadAppliedSet(ctx context.Context, d *sql.DB) (map[string]bool, error) {
	rows, err := d.QueryContext(ctx, `SELECT id FROM schema_migrations`)
	if err != nil {
		return nil, fmt.Errorf("query schema_migrations: %w", err)
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}

func applyMigration(ctx context.Context, d *sql.DB, m migration) error {
	tx, err := d.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, m.body); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO schema_migrations(id, applied_at) VALUES (?, ?)`,
		m.id, time.Now().UTC().Format(time.RFC3339),
	); err != nil {
		return err
	}
	return tx.Commit()
}
