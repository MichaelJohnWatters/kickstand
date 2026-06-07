# Kickstand — build status

State-of-build snapshot. The plan in `motorbike-training-plan.md` stays the design
source of truth; this doc tracks what's actually built and where to pick up.

Last updated: 2026-06-07

---

## Headline

All three apps (Student / Instructor / Admin) are functionally wired against a
single Go backend over HTTP, SQLite for now (Postgres later per plan §2).

- ~10k LOC backend / 4.5k LOC tests / 200+ tests across 9 packages, all green
- ~10k LOC Flutter app, analyzer clean, web release build succeeds
- No real user testing yet — only API-level smoke and unit tests

---

## Backend — `internal/`

| Package | What it does | Tests |
|---|---|---|
| `domain` | typed IDs, enums, entities | — |
| `tenant` | `Scope` guard — every query carries `school_id` (RLS stand-in until Postgres) | — |
| `db` | SQLite open with `_txlock=immediate` + per-connection PRAGMAs, migrations runner | ✓ |
| `auth` | login / logout / authenticate / bcrypt hash | ✓ |
| `booking` | book / cancel / reschedule / disruption (take offline + resolve) / browse listings | ✓ |
| `ledger` | student charges + payments + derived balance + history | ✓ |
| `instructorpay` | pay model + earnings + payments + outstanding (owed-tracking, NOT payroll) | ✓ |
| `progress` | attendance + competency assessment + session detail aggregation | ✓ |
| `records` | incidents + safety/progress notes + external (DVA/DVSA) tests | ✓ |
| `availability` | recurring slots + time-off | (HTTP tested) |
| `signup` | self-signup with onboarding-mode + approval queue | (HTTP tested) |
| `notify` | event/notification layer + producer hooks wired into bookings/disruptions | (HTTP tested) |
| `calendar` | master-calendar payload with travel warnings | (HTTP tested) |
| `logistics` | derived "bikes to move" query | (HTTP tested) |
| `admin` | CRUD: locations, travel-times, fleet, course types, competencies, staff, school settings | (HTTP tested) |
| `reminders` | cron-style worker: 24h/2h before-session reminders, idempotent | ✓ |
| `httpapi` | full REST surface w/ bearer-token auth + role gates + CORS | ✓ |

**Engine highlights** (the bits worth knowing about):

- **Booking transaction** (`booking.Book`) — single `BEGIN IMMEDIATE` tx, atomically
  checks session exists/future/scheduled, student active, instructor qualified,
  capacity, and "real" honest capacity (`min(capacity − active, suitable free bikes)`).
  Auto-assign picks same-location bikes first.
- **Partial unique index** on bookings keeps cancelled rows from blocking re-booking
  the same session (fixed in 0001 migration during early build).
- **Disruption flow** — `TakeBikeOffline` creates `bike_unavailability` + disruption
  record + flips affected bookings to `needs_reassignment` + computes live swap
  candidates. `ResolveAffectedBooking` applies swap (with re-verification under tx)
  or cancel-with-approval.
- **Notify hooks** fire inside the same tx as the engine action — a notification
  can never reference a booking that doesn't exist.
- **Reminders worker** normalises `now` to UTC before SQLite comparison (regression
  test covers this — local-time formatting silently broke the lexicographic compare).

---

## Flutter — `app/`

One codebase, three roles. Routed via `go_router` with auth-gate + role redirect.
Riverpod for state, Dio for HTTP, flutter_secure_storage for tokens, google_fonts
for Plus Jakarta Sans + Space Mono.

### Student app (mobile-first, bottom tab bar)

- Welcome (indigo full-bleed) / Login (pre-filled in dev)
- **Home** — greeting, pending-approval banner, hero card, browse CTA, quick-link to Licence
- **Book** (Browse) — list of upcoming sessions with **honest bike-aware capacity**,
  empty state, test-day badge
- **Review** → POST /bookings → **Confirmation** with advisories (CBT missing,
  theory missing, cross-site bike, etc.)
- **My bookings** — Upcoming / Past tabs, cancel sheet (policy-aware late flag),
  reschedule routes to Browse (MVP per plan §8)
- **Progress** — per-course rollup, progress bar, competency rows with status icons
- **Licence & docs** — provisional, CBT (variant + expiry + smart status pill),
  theory, DVA/DVSA test history
- **Notification bell** + center across all screens (polls every 60s, optimistic
  mark-read, category icons)

### Instructor app (mobile-first, bottom tab bar)

- **Schedule** — Day/Week toggle, prev/today/next chevrons, sessions as cards
- **Session detail** — student list with safety flags (amber, prominent), outstanding
  balance, bike assignment, quick Present/No-show buttons, "Assess →" tile
- **Assess** — per-booking screen with attendance toggle, competency rows with
  4-status chips, notes editor (autosaves on blur). Test-day branch shows
  "no assessment" banner per plan §3
- **In-field payment** — when school toggle on + student owes, tappable "Outstanding"
  row → sheet (amount pre-filled, method chips, optional notes) → POST /students/{id}/payments
- **Availability** — weekly view with per-day slot chips + add-slot sheet
  (weekday / start-end via TimePicker / location). Time-off list with date range + reason
- **Profile** — basics + sign out

### Admin app (web-first, responsive sidebar with drawer fallback)

All 11 sidebar items live:

- **Overview** — KPI grid (sessions today / bikes ready / bikes offline / pending
  sign-ups), "Needs attention" banner, today's sessions list
- **Master calendar** — week timeline, hour gridlines, sessions positioned by time
  with **multi-lane overlap handling**, course-coded colours, travel-warnings
  banner (expandable), per-session detail dialog
- **Students** — searchable table (name, status, lessons, balance, safety-flag icon).
  Tap → **detail aggregate**: header with balance + Record Payment, safety flags
  banner, progress per course, test history, financial card with stats + ledger,
  staff notes, incidents. Add charge + add note actions.
- **Sign-ups** — onboarding-mode picker (Open vs Approval, PATCH /school on change)
  + pending applicant cards with Approve / Reject
- **Bike fleet** — filter chips (category / status), table with Take Offline (with
  reason sheet) / Restore actions
- **Disruptions** — list with open badge, per disruption card with affected bookings
  and per-booking swap chips (live candidates) or Cancel-with-approval
- **Bike logistics** — date picker (defaults to tomorrow), destinations grouped,
  per-move row with **"Move done" button** that PUTs /bikes/{id}/move
- **Instructors** — staff cards in grid with quals chips, invite modal,
  edit-qualifications modal, school toggle "instructors can record payments"
- **Instructor pay** — indigo hero with total outstanding, per-instructor stats
  (Earned / Paid / Outstanding), Record Earning + Record Payment + Pay Model sheets
- **Locations** — cards with edit/delete, **travel-time matrix grid** (cells
  tappable to inline-edit minutes), school travel-buffer field
- **Course types** — cards in grid with all fields, region picker, prerequisites,
  competencies sheet with add/delete

### Cross-cutting

- **Role redirect** — `/student` / `/instructor` / `/admin` based on identity.role;
  cross-role URLs bounce to caller's home
- **Token storage** via flutter_secure_storage (Keychain/Keystore on mobile,
  localStorage on web)
- **API errors** — typed `ApiException` with stable `code`; screens branch on code
  for friendly copy (e.g. `capacity_full` vs `no_suitable_bike`)
- **Bottom sheets** — consistent grabber + content pattern, keyboard inset handled

---

## How to run

Backend + Flutter Web is the fastest dev loop:

```bash
# Once
make build            # builds Go binaries to ./bin/
make seed             # creates kickstand.db with the Lagan Valley demo tenant
make app-deps         # flutter pub get

# Per session — two terminals
make run              # Go server on :8765 (with reminders worker)
make app-run          # Flutter in Chrome (defaults to KS_API_BASE_URL=http://localhost:8765)
```

### Seeded credentials (`password` for all)

| Role | Email | Notes |
|---|---|---|
| Owner | `owen@lagan.test` | Full admin sidebar |
| Instructor | `dave@lagan.test` | Home: Belfast, qualified for everything |
| Instructor | `priya@lagan.test` | Home: Lisburn |
| Student (active) | `alex@test` | No CBT/theory; **outstanding £30**, **upcoming CBT in disruption** (bike offline), past completed + past cancelled bookings, progress note |
| Student (ready) | `maeve@test` | CBT held + theory passed, **safety flag** (glasses), upcoming practical + test-day, past completed practical with mixed-outcome competencies, incident on record |
| Student (pending) | `rowan@test` | Exercises the awaiting-approval state |
| Student (active) | `carlos@test` | Booked into the **fully-booked** CBT to demo capacity_full |

Seed includes 3 locations (Belfast / Lisburn / Newry), 5 NI course types (CBT
variants + Practical + Test day), 6 bikes across categories/transmissions (one
cross-site, **one currently offline**), travel-time matrix, instructor recurring
availability, one holiday on the books, and a live bike disruption with an
affected booking.

---

## What's NOT built

These are deferred deliberately, not bugs:

- **Push notifications via FCM** — Flutter has `device_tokens` table + endpoints
  ready, but no Firebase project configured. When you provide a service-account
  JSON + iOS/Android config files I can wire `firebase_messaging` in the client +
  the Go dispatcher. The in-app bell already works without it.
- **Notification preferences screen** — per-channel × per-category opt-outs (plan
  phase 2)
- **Booking-scoped messaging / chat** — plan §8b phase 3 with safeguarding work
- **GDPR data export / right-to-erasure flows** — plan §9 acknowledged
- **Audit trail UI** — the `recorded_by` field is on every relevant table for
  later
- **Stripe / online prepay** — plan phase 2
- **GPS history** — schema has the nullable fields; live map view deferred to
  phase 3
- **Real production deploy** — no Cloud Run / Cloudflare Pages config yet
- **Real user testing** — only API smoke + unit tests; UI testing is the next step
- **Multi-role user** — a user can hold only one role today; plan acknowledged
  this and we'd add a `user_roles` join table when a real use case appears

---

## Decisions made along the way (don't re-litigate)

- **Auth** — stuck with rolled-own (bcrypt + opaque session tokens in DB).
  Considered Supabase / Firebase Auth and deferred. Trigger to revisit: when we
  need password reset (regulated email-token flow). See
  `memory/project_auth_decision.md`.
- **SQLite first, Postgres later** — ANSI-ish SQL, no SQLite-isms. Migration path:
  swap driver + add RLS policies. See `memory/project_stack.md`.
- **Plan §9 leanings adopted** — bike location auto-updates from last session;
  "Any" bike auto-assigns at booking; disrupted bookings hold the slot. See
  `memory/project_plan_decisions.md`.
- **Backend stack chosen for Postgres-friendliness** — Go's `database/sql` is
  driver-portable; same code over modernc.org/sqlite now / pgx later.

---

## Known issues / things to fix when noticed

- [x] _Found during self-review 2026-06-07:_ Instructor "Assess" screen — saving
  notes didn't invalidate `sessionDetailProvider`, while the peer
  `markAttendance` / `assessCompetency` mutations did. Fixed in
  `app/lib/screens/instructor_assess_screen.dart`.
- [x] _Found during self-review 2026-06-07:_ Seed had a silent `INSERT OR IGNORE`
  failure on `bike_unavailability` (wrong column order + missed CHECK
  constraint: `reason` is an enum, free text belongs in `notes`). Fixed in
  `cmd/seed/main.go`. Lesson: SQLite `INSERT OR IGNORE` will swallow a CHECK
  failure — verify row counts after seeding, don't trust the empty stdout.
- [x] _Found during self-review 2026-06-07 (security):_ `booking.Cancel` and
  `booking.Reschedule` only filtered by `school_id`, not by the requesting
  student's `user_id`. Within the same school a student could cancel or
  reschedule another student's booking by passing the foreign booking ID.
  Fixed: added `ExpectedStudentID` to both `CancelRequest` and
  `RescheduleRequest`; mismatch returns `ErrBookingNotFound` (no leak). The
  HTTP handlers fill it in when the caller is a student. Regression tests:
  `TestCancel_ExpectedStudentMismatchRejected`,
  `TestReschedule_ExpectedStudentMismatchRejected`.
- [ ] _Add issues here as you click through_

---

## Picking back up

Quick path back into context:

1. Read this file
2. Skim `memory/MEMORY.md` if you're a new Claude session (it auto-loads)
3. `make seed && make run && make app-run` — clicking through Owen's admin or
   Alex's student flow re-greps the current behaviour quickly
4. Pick from "What's NOT built" or the issues list

### If you're a new Claude session

Most useful files to read for context:

- `motorbike-training-plan.md` — the canonical design
- `design_handoff_kickstand/README.md` — high-fidelity UI spec + token system
- `internal/booking/booking.go` — the constraint engine (plan §4)
- `internal/notify/notify.go` — event/notification design
- `app/lib/routing/router.dart` — the route map (gives you the screen list at a glance)
- `app/lib/api/client.dart` — the HTTP surface area

### If you (the human) are picking back up after a break

Likely next steps in priority order:

1. **UI testing** — actually drive each role in a browser. This will find layout,
   state-staleness, and error-handling bugs that engine tests can't.
2. **Production deploy** — pick a target (Cloud Run + Cloud SQL / Render / a Pi)
   and wire `KS_API_BASE_URL` accordingly. The Go server is a single static
   binary; the Flutter web build is `app/build/web/`.
3. **FCM** — set up a Firebase project, drop the config files, ask Claude to
   wire `firebase_messaging` + the Go dispatcher.
4. **Whatever surfaces from #1** — most likely small UI bugs once you click around.
