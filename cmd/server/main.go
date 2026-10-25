// Command server runs the Kickstand HTTP API.
//
// It opens the SQLite DB, runs migrations, and serves the API on -addr.
// Sessions persist across restarts; the DB is the only durable state.
package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/michaeljohnwatters/kickstand/internal/auth"
	"github.com/michaeljohnwatters/kickstand/internal/db"
	"github.com/michaeljohnwatters/kickstand/internal/email"
	"github.com/michaeljohnwatters/kickstand/internal/filestore"
	"github.com/michaeljohnwatters/kickstand/internal/httpapi"
	"github.com/michaeljohnwatters/kickstand/internal/logging"
	"github.com/michaeljohnwatters/kickstand/internal/notify"
	"github.com/michaeljohnwatters/kickstand/internal/reminders"
)

func main() {
	addr := flag.String("addr", ":8765", "HTTP listen address")
	dsn := flag.String("dsn", "kickstand.db", "SQLite database path")
	uploadsDir := flag.String("uploads-dir", "./uploads", "Where receipt photos (and any other blobs) are stored locally. Swap for a GCS client at deploy time.")
	remindersInterval := flag.Duration("reminders-interval", 5*time.Minute,
		"How often the session-reminder worker scans for due reminders. Set to 0 to disable.")
	emailInterval := flag.Duration("email-interval", time.Minute,
		"How often the email worker drains the outbox. Set to 0 to disable (also disabled if no sender configured).")
	logLevel := flag.String("log-level", "info", "Log level: debug|info|warn|error")
	maxBodyBytes := flag.Int64("max-body-bytes", 10<<20,
		"Maximum request body size in bytes (DoS guard). Covers receipt uploads; 0 disables the cap.")
	signupRatePerMin := flag.Int("signup-rate-per-min", 10,
		"Per-IP signup requests allowed per minute (abuse guard). 0 disables the limiter.")
	signupBurst := flag.Int("signup-burst", 5,
		"Per-IP burst capacity for the signup rate limiter.")
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

	// Production boot-gate: refuse to start with a dev/insecure config when
	// APP_ENV=production. Fail fast rather than ship a dev gate to prod.
	if problems := productionBootProblems(os.Getenv, fb != nil); len(problems) > 0 {
		for _, p := range problems {
			log.Error("production boot-gate failed", slog.String("problem", p))
		}
		os.Exit(1)
	}
	if os.Getenv("APP_ENV") == "production" {
		log.Info("production boot-gate: passed")
	}

	srv := httpapi.NewServer(d, files, fb)
	srv.MaxBodyBytes = *maxBodyBytes
	// Hand-rolled email/password auth: enabled when JWT_SIGNING_KEY is set.
	// The middleware then accepts our access tokens (preferred) with Firebase
	// as the migration fallback; /auth/login issues them.
	if key := os.Getenv("JWT_SIGNING_KEY"); key != "" {
		ts, err := auth.NewTokenService([]byte(key))
		if err != nil {
			log.Error("auth: invalid JWT_SIGNING_KEY", slog.String("err", err.Error()))
			os.Exit(1)
		}
		srv.Tokens = ts
		log.Info("auth: password login enabled (hand-rolled tokens)")
	}
	// CORS allow-list for production. Comma-separated origins, e.g.
	// "https://app.kickstand.example". Empty → dev mode (localhost only).
	if origins := os.Getenv("CORS_ALLOWED_ORIGINS"); origins != "" {
		srv.CORSAllowedOrigins = splitAndTrim(origins)
		log.Info("cors: production allow-list", slog.Any("origins", srv.CORSAllowedOrigins))
	} else {
		log.Info("cors: dev mode (localhost origins only)",
			slog.String("hint", "set CORS_ALLOWED_ORIGINS to your web origin(s) in production"))
	}
	srv.EnableSignupRateLimit(*signupRatePerMin, *signupBurst)
	if *signupRatePerMin > 0 {
		log.Info("signup rate limit enabled",
			slog.Int("per_min", *signupRatePerMin), slog.Int("burst", *signupBurst))
	} else {
		log.Info("signup rate limit disabled")
	}

	// Dedicated single-tenant instance: pin all signups to one school.
	if pin := os.Getenv("KS_SINGLE_TENANT_SCHOOL_ID"); pin != "" {
		srv.SingleTenantSchoolID = pin
		var exists int
		if err := d.QueryRowContext(rootCtx,
			`SELECT 1 FROM schools WHERE id = ?`, pin).Scan(&exists); err != nil {
			log.Warn("tenancy: single-tenant school not found yet — run `provision` for it",
				slog.String("school_id", pin))
		}
		log.Info("tenancy: single-tenant (pinned)", slog.String("school_id", pin))
	} else {
		log.Info("tenancy: shared multi-tenant")
	}

	// Optional crash-alert hook: POSTs panic details to ERROR_WEBHOOK
	// (Slack/Discord/collector). No-op if unset.
	httpapi.ErrorReporter = buildErrorReporter(log)

	httpSrv := &http.Server{
		Addr:    *addr,
		Handler: srv.Routes(),
		// Timeouts bound how long a single connection can tie up a goroutine,
		// closing the slow-body / idle-keep-alive exhaustion gap that
		// ReadHeaderTimeout alone leaves open. ReadTimeout is generous enough
		// for a receipt upload over a slow mobile link; WriteTimeout covers a
		// large data-export response.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      120 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	// Scheduled reminders worker. Runs in-process — one binary, no extra
	// ops. If we ever shard across replicas, only one should run this; for
	// now there's only one server.
	if *remindersInterval > 0 {
		go runRemindersWorker(rootCtx, d, *remindersInterval)
	}

	// Email worker: drains the notification outbox via the configured sender.
	// SMTP_HOST → real SMTP; else EMAIL_LOG=1 → log-only (dev); else email
	// stays queued but unsent (no worker), so bookings still succeed.
	sender := buildEmailSender(log)
	srv.EmailSender = sender                    // used for password-reset emails too
	srv.ResetURLBase = os.Getenv("WEB_APP_URL") // e.g. https://app.example/reset-password
	if sender != nil && *emailInterval > 0 {
		go runEmailWorker(rootCtx, d, sender, *emailInterval)
	} else {
		log.Info("email: disabled (no SMTP_HOST / EMAIL_LOG) — notifications queue but aren't emailed")
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

// buildEmailSender picks an email.Sender from the environment: a real SMTP
// relay when SMTP_HOST is set, a log-only sender when EMAIL_LOG=1 (dev),
// or nil (email disabled). Reads SMTP_HOST/PORT/USERNAME/PASSWORD and
// EMAIL_FROM / EMAIL_FROM_NAME.
func buildEmailSender(log *slog.Logger) email.Sender {
	if host := os.Getenv("SMTP_HOST"); host != "" {
		port := os.Getenv("SMTP_PORT")
		if port == "" {
			port = "587"
		}
		from := os.Getenv("EMAIL_FROM")
		if from == "" {
			from = os.Getenv("SMTP_USERNAME")
		}
		log.Info("email: SMTP sender", slog.String("host", host), slog.String("from", from))
		return &email.SMTPSender{
			Host:     host,
			Port:     port,
			Username: os.Getenv("SMTP_USERNAME"),
			Password: os.Getenv("SMTP_PASSWORD"),
			From:     from,
			FromName: os.Getenv("EMAIL_FROM_NAME"),
		}
	}
	if os.Getenv("EMAIL_LOG") == "1" {
		log.Info("email: log-only sender (EMAIL_LOG=1) — nothing actually sent")
		return email.LogSender{Log: log.With(slog.String("component", "email"))}
	}
	return nil
}

// buildErrorReporter returns a best-effort panic-alert hook posting to
// ERROR_WEBHOOK as {"text": "..."} (Slack/Discord-compatible), or nil when
// unset. Called asynchronously by the recover middleware.
func buildErrorReporter(log *slog.Logger) func(string) {
	url := os.Getenv("ERROR_WEBHOOK")
	if url == "" {
		return nil
	}
	log.Info("errors: webhook crash-alert enabled")
	return func(detail string) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		body := strings.NewReader(fmt.Sprintf(`{"text":%q}`, "Kickstand: "+detail))
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, body)
		if err != nil {
			return
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			log.Warn("error webhook post failed", slog.String("err", err.Error()))
			return
		}
		_ = resp.Body.Close()
	}
}

// runEmailWorker drains the email outbox on startup and every interval.
func runEmailWorker(ctx context.Context, d *sql.DB, sender email.Sender, interval time.Duration) {
	log := slog.Default().With(slog.String("component", "email"))
	log.Info("worker started", slog.Duration("interval", interval))
	defer log.Info("worker stopped")
	drain := func(now time.Time) {
		n, err := notify.DispatchEmails(ctx, d, sender, now, 0)
		if err != nil {
			log.Error("dispatch", slog.String("err", err.Error()))
		} else if n > 0 {
			log.Info("sent", slog.Int("count", n))
		}
	}
	drain(time.Now())
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			drain(now)
		}
	}
}

// productionBootProblems returns the reasons the server must refuse to boot
// when APP_ENV=production — a dev/insecure config reaching prod. Empty = safe.
// Pure (env injected) so it's unit-testable.
func productionBootProblems(get func(string) string, firebaseConfigured bool) []string {
	if get("APP_ENV") != "production" {
		return nil
	}
	var problems []string
	if get("CORS_ALLOWED_ORIGINS") == "" {
		problems = append(problems, "CORS_ALLOWED_ORIGINS must be set in production")
	}
	if get("FIREBASE_AUTH_EMULATOR_HOST") != "" {
		problems = append(problems, "FIREBASE_AUTH_EMULATOR_HOST must not be set in production")
	}
	if get("STORAGE_EMULATOR_HOST") != "" || get("FIREBASE_STORAGE_EMULATOR_HOST") != "" {
		problems = append(problems, "storage emulator env must not be set in production")
	}
	if !firebaseConfigured {
		problems = append(problems, "Firebase must be configured in production (GOOGLE_APPLICATION_CREDENTIALS + FIREBASE_PROJECT_ID)")
	}
	return problems
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

// splitAndTrim parses a comma-separated env value into a clean slice,
// dropping empty entries and surrounding whitespace.
func splitAndTrim(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
