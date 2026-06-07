package db_test

import (
	"context"
	"testing"

	"github.com/michaeljohnwatters/kickstand/internal/db"
)

func TestMigrateOnFreshInMemoryDB(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer d.Close()

	ctx := context.Background()
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	// Sanity: schools and bookings tables exist.
	var count int
	if err := d.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('schools','bookings','sessions','bikes')`,
	).Scan(&count); err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 4 {
		t.Fatalf("expected 4 core tables, got %d", count)
	}

	// Idempotency: second run is a no-op.
	if err := db.Migrate(ctx, d); err != nil {
		t.Fatalf("re-migrate: %v", err)
	}
}
