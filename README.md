# Kickstand

Multi-tenant SaaS for UK motorcycle training schools — backend.

Design specs and the build plan live in:
- `motorbike-training-plan.md` — authoritative behaviour
- `design_handoff_kickstand/` — high-fidelity HTML/React mockups (visual spec, not code to port)

## Stack

- **Go** backend (this directory)
- **SQLite** for development (`modernc.org/sqlite`, pure Go — no CGO)
- Postgres / Supabase target later; SQL is written ANSI-ish to ease the migration
- **Flutter** clients (iOS + Android + Flutter Web) — not yet started

## Layout

```
cmd/
  server/         HTTP API entrypoint
  seed/           Demo-tenant seeder
internal/
  domain/         Core types: IDs, enums, entities
  tenant/         Tenancy guard (SchoolID-required query helpers)
  db/             DB open + migrations runner
  booking/        The §4 booking constraint engine
migrations/       Numbered SQL migrations (*.up.sql / *.down.sql)
```

## Build — backend

```
make build       # compiles ./bin/server and ./bin/seed
make test        # runs all tests
make seed        # initialises SQLite + seeds Lagan Valley demo tenant
make run         # runs the server on :8080
```

## Build — Flutter app

The Flutter app lives in `app/` and is one codebase across roles (student / instructor / admin) and platforms (iOS / Android / Web).

```
make app-deps    # flutter pub get
make app-analyze # flutter analyze (static checks)
make app-web     # release build for Flutter Web → app/build/web
make app-run     # runs in Chrome by default; override: make app-run DEVICE=ios
```

### Local dev loop

In two terminals:
```
# terminal 1 — Go API
make seed && make run

# terminal 2 — Flutter app pointing at it
make app-run
```

Default API base is `http://localhost:8080`. Override at run time:
```
cd app && flutter run -d chrome --dart-define=KS_API_BASE_URL=https://api.example.com
```

### Seeded credentials (after `make seed`)

| Role | Email | Password |
|---|---|---|
| Student (active) | alex@test | password |
| Student (active, has CBT/theory) | maeve@test | password |
| Student (pending approval) | rowan@test | password |
| Instructor | dave@lagan.test | password |
| Instructor | priya@lagan.test | password |
