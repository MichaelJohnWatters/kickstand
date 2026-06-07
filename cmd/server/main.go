// Command server runs the Kickstand HTTP API.
//
// It opens the SQLite DB, runs migrations, and serves the API on -addr.
// Sessions persist across restarts; the DB is the only durable state.
package main

import (
	"context"
	"database/sql"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/filestore"
	"github.com/michaeljohnwatters/kickstand/internal/httpapi"
	"github.com/michaeljohnwatters/kickstand/internal/logging"
	"github.com/michaeljohnwatters/kickstand/internal/reminders"
)

func main() {
	addr := flag.String("addr", ":8765", "HTTP listen address")
	dsn := flag.String("dsn", "kickstand.db", "SQLite database path")
	uploadsDir := flag.String("uploads-dir", "./uploads", "Where receipt photos (and any other blobs) are stored locally. Swap for a GCS client at deploy time.")
	remindersInterval := flag.Duration("reminders-interval", 5*time.Minute,
		"How often the session-reminder worker scans for due reminders. Set to 0 to disable.")
	logLevel := flag.String("log-level", "info", "Log level: debug|info|warn|error")
	flag.Parse()

	logging.Setup(parseLevel(*logLevel))
	log := slog.Default()

	d, err := db.Open(*dsn)
	if err != nil {
		log.Error("open db", slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer d.Close()

	rootCtx, cancelRoot := context.WithCancel(context.Background())
	defer cancelRoot()

	if err := db.Migrate(rootCtx, d); err != nil {
		log.Error("migrate", slog.String("err", err.Error()))
		os.Exit(1)
	}

	files, err := filestore.NewLocal(*uploadsDir)
	if err != nil {
		log.Error("open uploads dir", slog.String("err", err.Error()))
		os.Exit(1)
	}

	srv := httpapi.NewServer(d, files)
	httpSrv := &http.Server{
		Addr:              *addr,
		Handler:           srv.Routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Scheduled reminders worker. Runs in-process — one binary, no extra
	// ops. If we ever shard across replicas, only one should run this; for
	// now there's only one server.
	if *remindersInterval > 0 {
		go runRemindersWorker(rootCtx, d, *remindersInterval)
	}

	// Graceful shutdown on SIGINT/SIGTERM.
	idleClosed := make(chan struct{})
	go func() {
		sigs := make(chan os.Signal, 1)
		signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
		<-sigs
		log.Info("shutdown: draining requests")
		cancelRoot() // stop the reminders worker
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpSrv.Shutdown(ctx); err != nil {
			log.Error("shutdown error", slog.String("err", err.Error()))
		}
		close(idleClosed)
	}()

	log.Info("kickstand: listening",
		slog.String("addr", *addr),
		slog.String("db", *dsn))
	if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Error("listen", slog.String("err", err.Error()))
		os.Exit(1)
	}
	<-idleClosed
	log.Info("shutdown: done")
}

// runRemindersWorker fires a reminders.Tick on startup and every interval
// thereafter, stopping when ctx is cancelled.
func runRemindersWorker(ctx context.Context, d *sql.DB, interval time.Duration) {
	log := slog.Default().With(slog.String("component", "reminders"))
	log.Info("worker started", slog.Duration("interval", interval))
	defer log.Info("worker stopped")
	// Run once immediately so demos see reminders without waiting up to a
	// full tick interval.
	if err := reminders.Tick(ctx, d, time.Now()); err != nil {
		log.Error("tick", slog.String("err", err.Error()))
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			if err := reminders.Tick(ctx, d, now); err != nil {
				log.Error("tick", slog.String("err", err.Error()))
			}
		}
	}
}

func parseLevel(s string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
