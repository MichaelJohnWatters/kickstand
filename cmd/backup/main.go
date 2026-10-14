// Command backup writes a consistent snapshot of the SQLite database using
// `VACUUM INTO`. Unlike copying the file, VACUUM INTO takes a read
// transaction and writes a clean, defragmented copy that is safe to take
// while the server is running — no need to stop the API.
//
// Restore is a file swap (see deploy/README.md): stop the server, move the
// snapshot over the live DB path, start again.
//
// Example (host):      bin/backup -dsn kickstand.db
// Example (container):  docker compose run --rm --entrypoint backup app \
//                         -dsn /data/kickstand.db -out /data/backups/snap.db
package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/logging"
)

func main() {
	dsn := flag.String("dsn", "kickstand.db", "SQLite database path to back up")
	out := flag.String("out", "", "Output snapshot path (default: <dsn-dir>/backups/kickstand-<UTC timestamp>.db)")
	flag.Parse()

	logging.Setup(slog.LevelInfo)
	log := slog.Default()
	ctx := context.Background()

	outPath := *out
	if outPath == "" {
		ts := time.Now().UTC().Format("20060102-150405")
		outPath = filepath.Join(filepath.Dir(*dsn), "backups", "kickstand-"+ts+".db")
	}

	d, err := db.Open(*dsn)
	if err != nil {
		log.Error("open db", slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer d.Close()

	if err := backupTo(ctx, d, outPath); err != nil {
		log.Error("backup failed", slog.String("err", err.Error()))
		os.Exit(1)
	}

	info, _ := os.Stat(outPath)
	var size int64
	if info != nil {
		size = info.Size()
	}
	fmt.Printf("✓ Backup written: %s (%d bytes)\n", outPath, size)
}

// backupTo writes a consistent snapshot of d to outPath via VACUUM INTO.
// The parent directory is created if missing. VACUUM INTO refuses to
// overwrite, so outPath must not already exist — callers use a unique
// (timestamped) name.
func backupTo(ctx context.Context, d *sql.DB, outPath string) error {
	if dir := filepath.Dir(outPath); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("create backup dir: %w", err)
		}
	}
	// VACUUM INTO binds the destination as a normal parameter.
	if _, err := d.ExecContext(ctx, `VACUUM INTO ?`, outPath); err != nil {
		return fmt.Errorf("vacuum into %s: %w", outPath, err)
	}
	return nil
}
