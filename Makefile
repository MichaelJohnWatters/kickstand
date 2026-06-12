.PHONY: build test test-noemu run seed seed-firebase backend demo-data web-demo marketing-demo clean tidy app-deps app-analyze app-web app-run emulator run-firebase

build:
	go build -o bin/server ./cmd/server
	go build -o bin/seed ./cmd/seed

# Full test suite — every httpapi test goes through the Firebase Auth
# emulator (Phase 1 of firebase-auth-migration.md). Receipt round-trip
# tests in internal/filestore additionally go through the Storage
# emulator when STORAGE_EMULATOR_HOST is set. Both tests t.Skip()
# themselves when the env isn't there, so plain `go test` is still a
# clean "ok" with most things exercised.
test:
	FIREBASE_AUTH_EMULATOR_HOST=localhost:19099 \
	FIREBASE_PROJECT_ID=kickstand-dev \
	STORAGE_EMULATOR_HOST=localhost:19199 \
	FIREBASE_STORAGE_BUCKET=kickstand-dev.appspot.com \
	go test ./...

# Run only the tests that don't need the emulator (everything outside
# internal/httpapi).
test-noemu:
	go test ./...

run: build
	./bin/server

seed: build
	./bin/seed

# Seed targeting the Firebase Auth emulator so each demo user is
# created in Firebase too (login via Flutter requires the user to
# exist on the Firebase side). Match the env to `make run-firebase`
# / `make emulator`. Re-running is idempotent — Firebase
# CreateUser ALREADY_EXISTS errors are swallowed by the seeder.
#
# If you previously ran plain `make seed` against the same DB, the
# local rows exist with NULL firebase_uid and INSERT OR IGNORE will
# skip them. `make clean && make seed-firebase` is the reliable
# reset.
seed-firebase: build
	FIREBASE_AUTH_EMULATOR_HOST=localhost:19099 \
	FIREBASE_PROJECT_ID=kickstand-dev \
	STORAGE_EMULATOR_HOST=localhost:19199 \
	FIREBASE_STORAGE_BUCKET=kickstand-dev.appspot.com \
	./bin/seed

# Dump the running backend's JSON responses into app/assets/demo/
# for the static demo-mode Flutter build. Requires `make backend`
# already running in another tab (emulators + Go server). Uses the
# same JSON shapes the real ApiClient parses — single source of truth,
# no duplicated payload-shaping logic.
demo-data:
	./scripts/dump-demo.sh

# One-shot backend reset + start:
#   1. Wipe the local SQLite DB.
#   2. Wipe every user in the Firebase Auth emulator + every blob in
#      the Storage emulator (REST DELETE on the emulator-specific
#      endpoints; silent if the emulators aren't running).
#   3. Re-seed against the emulators (new SQLite rows + matching
#      Firebase users).
#   4. Start the Go server.
#
# Assumes `make emulator` is already running in another tab. Use
# this any time login starts misbehaving for a known-good seeded
# user, or after schema changes.
backend: clean
	@echo "wiping Firebase Auth emulator users..."
	@curl -sf -X DELETE "http://localhost:19099/emulator/v1/projects/kickstand-dev/accounts" > /dev/null || \
		echo "  (Auth emulator not reachable — skipping)"
	@echo "wiping Firebase Storage emulator bucket..."
	@curl -sf -X DELETE "http://localhost:19199/storage/v1/b/kickstand-dev.appspot.com/o" > /dev/null || \
		echo "  (Storage emulator not reachable — skipping)"
	$(MAKE) seed-firebase
	$(MAKE) run-firebase

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

# ----- Firebase emulator -----
# Local Auth (19099) + Storage (19199) + UI (14000) + Hub (14400)
# + Logging (14500). Non-default ports in the 14000/19000 range so
# they coexist with any other Firebase project on this dev machine
# (Firebase's defaults are 9099/9199/4000/4400/4500). Needs Node ≥20 and
# Java ≥11. Project alias 'kickstand-dev' (see .firebaserc); zero Google
# account required for the emulator itself.
#
# Typical dev loop:
#   tab 1:  make emulator       # Firebase Auth + Storage + UI
#   tab 2:  make run-firebase   # Go server pointing at the emulator
#   tab 3:  make app-run        # Flutter, talks to both
emulator:
	firebase emulators:start --only auth,storage,ui --project kickstand-dev

# Run the Go server with Firebase-JWT verification + Firebase Storage
# enabled, pointing at the local emulator suite. Use in tandem with
# `make emulator` in another tab.
run-firebase: build
	FIREBASE_AUTH_EMULATOR_HOST=localhost:19099 \
	FIREBASE_PROJECT_ID=kickstand-dev \
	STORAGE_EMULATOR_HOST=localhost:19199 \
	FIREBASE_STORAGE_BUCKET=kickstand-dev.appspot.com \
	./bin/server
