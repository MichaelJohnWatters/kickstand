# Kickstand

Multi-tenant SaaS for UK motorcycle training schools — a full-stack demo build:
a Go backend and a single Flutter codebase serving three roles (student,
instructor, admin/owner) across iOS, Android, and Flutter Web.

The demo tenant is **Lagan Valley Rider Training** (Northern Ireland — Belfast /
Lisburn / Newry). Region-aware by design: course and test structure is per-school
(NI's CBT → theory → practical, not GB's Mod 1 / Mod 2 hardcoded).

Two docs carry the detail:
- **[`STATUS.md`](STATUS.md)** — what's actually built, package by package and
  screen by screen. Start here.
- **[`motorbike-training-plan.md`](motorbike-training-plan.md)** — the authoritative
  design and behaviour spec.
- **[`design_handoff_kickstand/`](design_handoff_kickstand/)** — the original
  high-fidelity HTML/React mockups (visual spec + design tokens; archived, not code
  to port).

## Stack

- **Go** backend — `net/http`, `database/sql`, 200+ tests (all green)
- **SQLite** for development (`modernc.org/sqlite`, pure Go — no CGO); SQL kept
  ANSI-ish for a later **Postgres / Supabase** migration
- **Firebase Auth** — ID-token verification in the backend, `firebase_auth` in the
  Flutter client; local dev and tests run against the Firebase Auth emulator
- **Flutter** client — one codebase, three roles; `go_router` (auth-gate + role
  redirect), Riverpod, Dio, `flutter_secure_storage`

## Layout

```
cmd/
  server/             HTTP API entrypoint (serves :8765)
  seed/               Lagan Valley demo-tenant seeder
  teltonika-adapter/  Teltonika Codec-8 GPS tracker → API bridge
  gps-simulator/      synthetic GPS fixes for the live map
internal/             domain, tenant guard, db+migrations, and the engines
                      (booking, ledger, instructorpay, progress, records,
                      availability, signup, notify, calendar, logistics,
                      admin, analytics, reminders, httpapi, …)
migrations/           numbered SQL migrations (*.up.sql / *.down.sql)
app/                  the Flutter client (see app/README.md)
design_handoff_kickstand/  archived HTML/React design prototype
dist/marketing/       static demo-mode build + marketing wrapper
```

## Run it

Fastest full-app loop is the Go backend + Flutter Web against the Firebase Auth
emulator (login needs the demo users to exist on the Firebase side). Three
terminals, after a one-time `make build && make app-deps`:

```bash
make emulator        # tab 1 — Firebase Auth + Storage emulators
make seed-firebase   # once  — seeds SQLite + matching Firebase users
make run-firebase    # tab 2 — Go server on :8765, wired to the emulator
make app-run         # tab 3 — Flutter in Chrome (override: make app-run DEVICE=ios)
```

API-only (no Flutter login) is simpler — `make seed && make run`. Point the client
elsewhere at build time with `--dart-define=KS_API_BASE_URL=https://api.example.com`.

Needs Node ≥20 and Java ≥11 for the emulator. See
[`firebase-auth-migration.md`](firebase-auth-migration.md) for the auth setup and
`make help`-worthy targets in the [`Makefile`](Makefile) (`make test`, `make web-demo`,
`make marketing-demo`, …).

### Seeded credentials

Password is `password` for every account.

| Role | Email | Notes |
|---|---|---|
| Owner | `owen@lagan.test` | full admin sidebar |
| Instructor | `dave@lagan.test` | Belfast, qualified for everything |
| Instructor | `priya@lagan.test` | Lisburn |
| Student (active) | `alex@test` | outstanding £30, a booking caught in a live disruption |
| Student (ready) | `maeve@test` | CBT + theory done, safety flag, upcoming practical + test day |
| Student (pending) | `rowan@test` | exercises the awaiting-approval state |
| Student (active) | `carlos@test` | booked into a full session to demo `capacity_full` |

## Status & caveats

This is a demo / portfolio build: functionally wired end-to-end with unit and
API-level tests, but **no real-user UI testing yet** and **no production deploy**.
Push notifications (FCM), DVLA polling, and online prepay (Stripe) are deliberately
stubbed — see the "What's NOT built" section of [`STATUS.md`](STATUS.md).
