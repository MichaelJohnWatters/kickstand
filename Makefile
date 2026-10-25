.PHONY: build test run seed backend demo-data web-demo marketing-demo clean tidy app-deps app-analyze app-web app-run backup

# Dev-only HS256 signing key for local auth. NEVER use in production — prod
# sets its own JWT_SIGNING_KEY (≥32 random bytes, e.g. `openssl rand -base64 48`).
DEV_JWT_SIGNING_KEY ?= dev-insecure-signing-key-change-me-0123456789

build:
	go build -o bin/server ./cmd/server
	go build -o bin/seed ./cmd/seed
	go build -o bin/provision ./cmd/provision
	go build -o bin/backup ./cmd/backup
	go build -o bin/teltonika-adapter ./cmd/teltonika-adapter
	go build -o bin/gps-simulator ./cmd/gps-simulator

# Consistent snapshot of the dev DB (VACUUM INTO) — safe while `make run`
# is going. Writes to ./backups/kickstand-<timestamp>.db.
backup:
	go run ./cmd/backup -dsn kickstand.db

# Full test suite — auth is hand-rolled (no emulator), so this is just a
# plain run. The internal/filestore receipt tests exercise GCS only when
# STORAGE_EMULATOR_HOST points at a storage emulator; otherwise they
# t.Skip(), so `go test ./...` is a clean "ok" with most things exercised.
test:
	go test ./...

# Dev server with local email/password auth enabled. EMAIL_LOG=1 prints
# password-reset links to the log instead of sending real mail.
run: build
	JWT_SIGNING_KEY=$(DEV_JWT_SIGNING_KEY) EMAIL_LOG=1 ./bin/server

seed: build
	./bin/seed

# Dump the running backend's JSON responses into app/assets/demo/
# for the static demo-mode Flutter build. Requires `make backend`
# already running in another tab. Uses the same JSON shapes the real
# ApiClient parses — single source of truth, no duplicated payload-shaping.
demo-data:
	./scripts/dump-demo.sh

# One-shot backend reset + start: wipe the local SQLite DB, re-seed the
# demo tenant, then run the server with the dev signing key. Use any time
# login starts misbehaving for a known-good seeded user, or after schema
# changes. Every demo user's password is "password".
backend: clean
	$(MAKE) seed
	$(MAKE) run

tidy:
	go mod tidy

clean:
	rm -rf bin/ *.db *.db-journal

# ----- Flutter -----

app-deps:
	cd app && flutter pub get

app-analyze:
	cd app && flutter analyze

app-web:
	cd app && flutter build web --release --no-tree-shake-icons

# Static marketing bundle. Re-uses the original JSX design wrapper
# from design_handoff_kickstand/ — the launcher, role tiles, top
# bar and tweaks panel — and embeds the real Flutter app (built
# with KS_DEMO_MODE=true) inside its stage frame via an iframe.
# Output is dist/marketing/ — drop onto any static host.
#
#   dist/marketing/
#     Kickstand.html    — original design shell (entry point)
#     app/, frames/     — JSX prototype assets (shell, launcher, tweaks)
#     demo/             — the Flutter web app served at /demo/
#
# Re-run `make demo-data` first if the Go seed has changed.
web-demo:
	cd app && flutter build web --release \
		--dart-define=KS_DEMO_MODE=true \
		--no-tree-shake-icons \
		--base-href=/demo/
	rm -rf dist/marketing
	mkdir -p dist/marketing/demo
	cp -R app/build/web/. dist/marketing/demo/
	# Original design wrapper — Kickstand.html plus its JSX assets.
	cp design_handoff_kickstand/Kickstand.html dist/marketing/index.html
	cp -R design_handoff_kickstand/app    dist/marketing/app
	cp -R design_handoff_kickstand/frames dist/marketing/frames
	@echo ""
	@echo "Built dist/marketing/. Preview with: make marketing-demo"

# Full marketing-demo pipeline: regenerate seed JSON from the
# running backend, rebuild the static marketing+demo bundle, then
# serve dist/marketing/ on :8080. Requires `make backend` already
# running in another tab. Ctrl-C stops the preview server; the
# dist/ bundle stays for upload to your CDN.
MARKETING_PORT ?= 8080
marketing-demo: demo-data web-demo
	@echo ""
	@echo "Marketing demo live at: http://localhost:$(MARKETING_PORT)/"
	@echo "(Ctrl-C to stop. dist/marketing/ persists for upload.)"
	@cd dist/marketing && python3 -m http.server $(MARKETING_PORT)

# Run the Flutter app against the Go server on localhost:8765.
# Default device is Chrome; override with DEVICE=ios, web-server etc.
DEVICE ?= chrome
app-run:
	cd app && flutter run -d $(DEVICE)
