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

	"github.com/michaeljohnwatters/kickstand/internal/auth"
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

	// Receipt storage: prefer Firebase Storage / GCS when configured,
	// fall back to the local-disk implementation. NewGCS returns
	// (nil, nil) when no bucket env var is set, so we can pick by the
	// returned value without a separate "are we configured" probe.
	var files filestore.Store
	gcs, err := filestore.NewGCS(rootCtx)
	if err != nil {
		log.Error("filestore: gcs init", slog.String("err", err.Error()))
		os.Exit(1)
	}
	if gcs != nil {
		files = gcs
		mode := "production"
		if os.Getenv("STORAGE_EMULATOR_HOST") != "" || os.Getenv("FIREBASE_STORAGE_EMULATOR_HOST") != "" {
			mode = "emulator"
		}
		log.Info("filestore: firebase storage",
			slog.String("mode", mode),
			slog.String("bucket", os.Getenv("FIREBASE_STORAGE_BUCKET")))
	} else {
		local, err := filestore.NewLocal(*uploadsDir)
		if err != nil {
			log.Error("open uploads dir", slog.String("err", err.Error()))
			os.Exit(1)
		}
		files = local
		log.Info("filestore: local disk", slog.String("dir", *uploadsDir))
	}

	// Firebase Admin SDK — returns (nil, nil) when no Firebase env vars
	// are set. The HTTP middleware dispatches by token shape, so when
	// `fb == nil` only legacy opaque tokens work; a Firebase JWT lands
	// at 401 because there's nothing to verify it against. Log the mode
	// once so a sleepy dev can spot misconfig at a glance.
	fb, err := auth.NewFirebaseClient(rootCtx)
	if err != nil {
		log.Error("firebase init", slog.String("err", err.Error()))
		os.Exit(1)
	}
	switch {
	case fb == nil:
		log.Info("auth: legacy session-token mode only",
			slog.String("hint", "set FIREBASE_AUTH_EMULATOR_HOST or GOOGLE_APPLICATION_CREDENTIALS to enable Firebase JWT verification"))
	case os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") != "":
		log.Info("auth: firebase enabled (emulator)",
			slog.String("emulator", os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")),
			slog.String("project", os.Getenv("FIREBASE_PROJECT_ID")))
	default:
		log.Info("auth: firebase enabled (production credentials)",
			slog.String("project", os.Getenv("FIREBASE_PROJECT_ID")))
	}

	srv := httpapi.NewServer(d, files, fb)
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
