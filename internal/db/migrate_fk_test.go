package db

import (
	"context"
	"testing"
)

// A table-rebuild migration (DROP + recreate + rename a FK-referenced table)
// must succeed even when the DB already holds child rows pointing at the table.
// This is the regression for the "PRAGMA foreign_keys=OFF is a no-op inside the
// migration runner's transaction" bug: the runner now disables FK enforcement
// on a dedicated connection *before* the tx, so the DROP no longer trips a
// FOREIGN KEY constraint (787) on a populated database.
func TestApplyMigration_RebuildTableWithChildRows(t *testing.T) {
	ctx := context.Background()
	d, err := Open(t.TempDir() + "/t.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer d.Close()
	// Migrate() sets up schema_migrations (which applyMigration writes to).
	if err := Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	// Toy FK-referenced table, populated with a child row — the exact shape
	// that made DROP fail before the fix.
	if _, err := d.ExecContext(ctx, `
		CREATE TABLE p (id TEXT PRIMARY KEY, label TEXT);
		CREATE TABLE c (id TEXT PRIMARY KEY, p_id TEXT NOT NULL REFERENCES p(id));
		INSERT INTO p (id, label) VALUES ('p1', 'before');
		INSERT INTO c (id, p_id) VALUES ('c1', 'p1');
	`); err != nil {
		t.Fatalf("seed: %v", err)
	}

	m := migration{id: "9999_test_rebuild", body: `
		CREATE TABLE p_new (id TEXT PRIMARY KEY, label TEXT);
		INSERT INTO p_new SELECT id, label FROM p;
		DROP TABLE p;
		ALTER TABLE p_new RENAME TO p;
	`}
	if err := applyMigration(ctx, d, m); err != nil {
		t.Fatalf("rebuild migration on populated DB failed: %v", err)
	}

	// Data survived, the child FK still resolves, and FK enforcement is back
	// on for the connection pool.
	var n int
	if err := d.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM c JOIN p ON p.id = c.p_id`).Scan(&n); err != nil {
		t.Fatalf("post-rebuild join: %v", err)
	}
	if n != 1 {
		t.Fatalf("expected 1 joined row after rebuild, got %d", n)
	}
	var fk int
	if err := d.QueryRowContext(ctx, `PRAGMA foreign_keys`).Scan(&fk); err != nil {
		t.Fatalf("read foreign_keys pragma: %v", err)
	}
	if fk != 1 {
		t.Errorf("foreign_keys left disabled on a pooled connection (got %d)", fk)
	}
	// The migration was recorded.
	var applied int
	if err := d.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM schema_migrations WHERE id = '9999_test_rebuild'`).Scan(&applied); err != nil {
		t.Fatalf("schema_migrations check: %v", err)
	}
	if applied != 1 {
		t.Errorf("migration not recorded in schema_migrations")
	}
}

// foreign_key_check backstop: a migration that leaves a dangling reference
// (FK was off during apply) must be rejected, not silently committed.
func TestApplyMigration_RejectsDanglingReference(t *testing.T) {
	ctx := context.Background()
	d, err := Open(t.TempDir() + "/t.db")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer d.Close()
	if err := Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if _, err := d.ExecContext(ctx, `
		CREATE TABLE p (id TEXT PRIMARY KEY);
		CREATE TABLE c (id TEXT PRIMARY KEY, p_id TEXT NOT NULL REFERENCES p(id));
		INSERT INTO p (id) VALUES ('p1');
		INSERT INTO c (id, p_id) VALUES ('c1', 'p1');
	`); err != nil {
		t.Fatalf("seed: %v", err)
	}
	// Delete the parent row a child still points at. With FK off during apply
	// SQLite allows it; the foreign_key_check backstop must catch it.
	bad := migration{id: "9999_bad", body: `DELETE FROM p WHERE id = 'p1';`}
	if err := applyMigration(ctx, d, bad); err == nil {
		t.Fatal("expected applyMigration to reject a migration leaving a dangling FK, got nil")
	}
}
