package main

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
)

func TestBackupTo_ProducesConsistentCopy(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()

	d, err := db.Open(filepath.Join(dir, "live.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer d.Close()
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := d.ExecContext(ctx,
		`INSERT INTO schools (id, name, region, test_body_label, created_at)
		 VALUES ('sch-1', 'Test', 'NI', 'DVA', ?)`, now); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Back up into a fresh (non-existent) path — note the nested dir is created.
	out := filepath.Join(dir, "backups", "snap.db")
	if err := backupTo(ctx, d, out); err != nil {
		t.Fatalf("backup: %v", err)
	}

	// The snapshot opens independently and carries the row.
	b, err := db.Open(out)
	if err != nil {
		t.Fatalf("open backup: %v", err)
	}
	defer b.Close()
	var n int
	if err := b.QueryRowContext(ctx, `SELECT COUNT(*) FROM schools WHERE id = 'sch-1'`).Scan(&n); err != nil {
		t.Fatalf("read backup: %v", err)
	}
	if n != 1 {
		t.Fatalf("backup missing seeded row: got %d schools, want 1", n)
	}
}

func TestBackupTo_RefusesExistingFile(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "live.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer d.Close()
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	out := filepath.Join(dir, "snap.db")
	if err := backupTo(ctx, d, out); err != nil {
		t.Fatalf("first backup: %v", err)
	}
	// VACUUM INTO must not clobber an existing snapshot (timestamped names
	// avoid this in practice; assert the guard so a reused name errors loudly).
	if err := backupTo(ctx, d, out); err == nil {
		t.Fatal("expected backup to an existing path to fail, got nil")
	}
}
