# Kickstand — build status

State-of-build snapshot. The plan in `motorbike-training-plan.md` stays the design
source of truth; this doc tracks what's actually built and where to pick up.

Last updated: 2026-06-11

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
  candidates. `ResolveAffectedBooking` routes to one of three engine paths:
  `applySwapInTx` (re-validates suitability under tx), `applyCancelWithApprovalInTx`
  (voids the auto-charge in the same tx — added 2026-06 because cancel-without-void
  left students with stuck charges for a session that didn't happen), and
  `applyDismissInTx` (post-session cleanup — only closes the disruption link, leaves
  booking + charge untouched because the session has come and gone). The dismissed
  resolution kind landed in migration 0023 (SQLite table rebuild to extend the CHECK).
- **Disruption candidate enrichment** — swap candidates surfaced via `ListDisruptions`
  carry: bike nickname + reg, current location id + name, `isCrossSite`, raw
  `travelMinutes` from the school's travel-times matrix, and a `tightFromPrior`
  flag computed by `findPriorBookingForBike` (back-to-back move feasibility check
  using `travel_buffer_minutes`). Engine never filters tight candidates out — UI
  decides whether to warn.
- **Standalone bike swap** (`booking.AssignBike` / `POST /bookings/{id}/assign-bike`)
  — reuses `findSuitableFreeBikes` for the master-calendar edit-sheet swap picker
  without the disruption bookkeeping. Idempotent on same-bike re-pin.
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

Realigned to `design_handoff_kickstand/app/instructor.jsx` 2026-06. Shared
`KsAvatar` widget + `courseColour()` util introduced.

- **Schedule** — instructor-name eyebrow above big "Schedule" title, pill Day/Week
  toggle, **Mine / All instructors** scope toggle (drives `?instructorId=…` on
  the calendar endpoint). Session cards have a 5px course-coloured left stripe,
  mono course code, course name, meta row (time / location / instructor name when
  All / student count), avatar pile of students. Week view is a 7-row mini-calendar
  with day-number bubbles + tinted session chips.
- **Session detail** — header with back button + course code (mono, course
  colour) + course name; date/time/location summary card; **Bikes** section
  above the roster listing each unique bike with a "Take offline" action
  (start-of-day check); roster cards with avatar, bike-with-reg in mono, phone
  button, safety-flag banner, outstanding (red) vs **Paid in full** (green tile);
  Present/No-show pills + Assess + **Report incident** all sit in the same row.
- **Report incident** — bottom sheet with description textarea, prominent BIKE
  card, optional "Take bike offline" toggle (reveals reason chips). Backend's
  `POST /incidents` accepts the toggle so an instructor reporting a crash takes
  the bike out of service in one tap.
- **Take bike offline** — sister sheet (reason chips + notes, no description)
  for proactive maintenance flagging.
- **Assess** — rebuilt against the design: header with progress ring
  (`KsProgressRing`, custom-paint arc), big student name + "Assess · Course"
  eyebrow, compact Present/No-show row, test-day banner replaces competencies on
  non-teaching, safety-flag banner, competencies card with one row per item
  (22px tick square + 4 status pills), notes textarea in mono. Done button at the
  bottom + autosave reassurance.
- **In-field payment** — when school toggle on + student owes, tappable
  Outstanding row → sheet → POST /students/{id}/payments.
- **Availability** — instructor-name eyebrow header, kept the time-range slot
  model (richer than the design's morning/afternoon/evening simplification).
- **Profile** — centred 84px avatar + name + "Instructor · Location",
  **Accredited to teach** list (per-course expiry dates with green check),
  notification preferences + sign-out rows.
- **Expenses** — list page with outstanding hero + Pending / Approved / Reimbursed
  / Rejected sections. **Add expense** opens the modal immediately with fields
  first; receipt attaches via a button at the bottom of the form that opens a
  3-option chooser (camera / photo library / file via `file_picker`). Receipts
  held as `Uint8List` bytes + multipart upload — web-compatible (Image.file +
  MultipartFile.fromFile were the previous Web blockers).

### Admin app (web-first, responsive sidebar with drawer fallback)

All sidebar items live:

- **Overview** — KPI grid, "Needs attention" banner, today's sessions list.
- **Master calendar** — densely interactive:
  - Day / 3-day / Week / Month views, hour gridlines, multi-lane overlap layout,
    course-coded colours via shared `courseColour()` resolver.
  - **Click empty time slot** → opens add-session sheet anchored to that day +
    snapped time. **Click date strip in month view** → same. Existing sessions
    open a detail dialog.
  - **Drag a session block to reschedule** — long-press to start, ghost feedback
    follows the pointer, day column highlights on hover. `PATCH /sessions/{id}`
    with snapped (15-min) new start; preserves duration; toast confirms.
  - **Edit session sheet** (Edit button on the detail dialog) — date / start /
    duration / capacity / instructors multi-select with "Unassigned" chip;
    **Bikes** section with `Assigned · N` subsection (Take offline per row) and
    **Free in this slot · N** subsection (suitable-free bikes with travel-time
    badge for cross-site, plus Take offline action); **Roster** with add student
    (search-picker over `/students` excluding already-booked) + remove (`DELETE
    /bookings/{id}`) + per-row bike swap chip (`POST /bookings/{id}/assign-bike`,
    opens picker over `/sessions/{id}/suitable-bikes`); status pills on each row
    (Booked / Bike issue / No-show / Cancelled / Done) with tooltips.
  - **Cancel session** button on the detail dialog with confirm dialog.
  - **Course filter chips** carry an 8px coloured dot matching session blocks.
  - **Multi-select** for bulk-cancel (renamed from "Select"), tooltip explains.
  - **Show cancelled** toggle (off by default) — when on, cancelled sessions
    reappear faded (40% opacity, diagonal strike, "Cancelled" pill) and
    cancelled bookings appear in the student avatar pile with red strikethrough
    and a "N cancelled" counter under the roster. Backend respects
    `?includeCancelled=true`.
  - **Per-status icons in the block** — `needs_reassignment` (amber ⚠),
    `no_show` (red ✕ + red strikethrough), `cancelled` (red strikethrough),
    `completed` (green name), `booked` (default).
  - **Tight-travel banner** collapses to a single summary chip ("⚠️ N tight-travel
    warnings · tap to view") with an expand toggle.
  - **Block overflow** clipped (`Clip.antiAlias`) so short-duration blocks
    don't bleed text into neighbours.
- **Students** — searchable table with stage / balance / safety-flag icon. Detail
  aggregate page with Record Payment, safety flags, progress per course, tests,
  financial card with ledger, staff notes, incidents.
- **Sign-ups** — onboarding-mode picker (Open vs Approval), **Pending / Rejected
  tabs** with live counts:
  - Pending: Approve (indigo) + Reject (outlined), Pending badge.
  - **Rejected**: Restore button (indigo, replay icon) + explainer text, Rejected
    badge. Engine guards restore on no-booking-history so only signup-time
    rejections can be reversed (`signup.Restore` / `POST /signups/{id}/restore`).
- **Bike fleet** — filter chips, Take Offline (reason sheet) / Restore actions.
- **Disruptions** — list with open badge; per-affected-booking card now uses a
  `_CandidateGrid` of colour-coded tiles instead of one suggested swap:
  - Green tile: same-site bike (drop-in swap).
  - Amber tile: cross-site **future** session (logistics page picks up the move).
  - Yellow tile: cross-site **same-day** session — tapping fires a confirm
    dialog with travel time + feasibility hint ("25-min drive — tight" /
    "borderline" / clear).
  - Red **"Just finished at Lisburn · 08:30"** chip overlays a tile when the
    engine's `tightFromPrior` check fires.
  - "None of these — cancel booking" fallback.
  - **Past-due banner** at the top sweeps stale rows in one tx
    (`POST /disruptions/dismiss-past`). Per-row Dismiss button appears on stale
    cards as an alternative.
  - "Past · needs cleanup" pill on stale affected-booking cards.
- **Bike logistics** — date picker (defaults to tomorrow), per-move row with Move
  done. Picks up cross-site bike swaps automatically (derived query against
  bookings + bikes.current_location_id ≠ sessions.location_id).
- **Instructors** — staff cards with **per-course accreditation** chips (each
  with expiry date). Edit sheet has a date picker per course. Invite modal too.
- **Instructor pay** — hero with total outstanding, per-instructor stats,
  Record Earning / Record Payment / Pay Model sheets.
- **Locations** — travel-time matrix grid (inline-editable), travel-buffer field.
- **Course types** — full editor with competencies sheet.
- **Audit log** — searchable timeline; entity colour-stripe + tinted icon circle
  per row (bikes orange, students/instructors indigo, bookings sky-blue, money
  green, setup purple, risk red), **coloured role pill** after the actor name
  (OWNER purple, ADMIN indigo, INSTRUCTOR teal, STUDENT sky-blue).
- **Reimbursements** — admin reviews instructor expenses (approve / reject /
  reimburse).
- **Templates** — recurring schedules with "Unassigned" instructor chip; Generate
  next-N-weeks CTA.
- **Compliance** — bike MOT/tax + instructor accreditation + insurance dashboard.
  Per-instructor accreditation list with course-coloured chips, worst-of status.

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

Firebase Auth is live (Phases 0–5 + 1b + the all-emulator test
migration landed 2026-06-08). Local dev and tests both go through the
emulator — the Go backend takes
`FIREBASE_AUTH_EMULATOR_HOST=localhost:9099`, the Flutter client uses
`useAuthEmulator` in debug builds, and every httpapi test mints real
Firebase ID tokens via the Auth Emulator. The legacy session-token
validation path, `/auth/login`, `/auth/logout`, `/auth/signup`,
`internal/auth.Login`/`Authenticate`/`Logout`/`HashPassword` and the
bcrypt module are all deleted. The `user_sessions` table and
`password_hash` column survive only as vestigial NOT NULL columns
until a follow-up migration drops them. Storage emulator is
scaffolded but dormant until Phase 6.

```bash
make emulator         # http://localhost:4000 — Auth on 9099, Storage on 9199
make run-firebase     # Go server wired to the Auth emulator
```

Needs Node ≥20 and Java ≥11. See `firebase-auth-migration.md` for the
plan and `firebase.json` for the config.

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

Seed includes 3 locations (Belfast / Lisburn / Newry), 6 NI course types (CBT
125 / 650 + MOD 1/2 practice + MOD 1/2 test), 7 bikes across
categories/transmissions, travel-time matrix, instructor recurring availability,
school closure, and:

- **Bulk calendar fill** — ±2 weeks of recurring sessions on a fixed weekly
  pattern so the master calendar feels populated without 50 hand-written rows.
- **Live disruption** (broken-clutch YBR125): Alex + Ryan pending, Niamh already
  swapped. Exercises the suggestion grid, "no candidate" fallback, swap-applied
  status badge.
- **Past-due disruption** (Honda CB500F #2 — overran service): bike was restored
  but Emma's MOD 2 affected booking sat past session end. Exercises "Past · needs
  cleanup" pill + bulk Dismiss banner + per-row Dismiss button.
- **Tight-from-prior demo**: Mark on Honda CB125F at Lisburn 04:30–08:30
  tomorrow; Alex's disrupted Belfast CBT starts 09:00. 30-min gap < 25-min drive
  + 15-min buffer → red "Just finished at Lisburn · 08:30" pill renders on the
  candidate tile.
- **No-show booking**: Mark missing today's morning CBT (red ✕ on calendar).
- **Cancelled booking on future session**: Jordan cancelled tomorrow's Belfast
  CBT (faded with strikethrough + "1 cancelled" line when toggle on).
- **Fully cancelled session**: a CBT-650 at Newry 2 days out (diagonal
  strikethrough + "Cancelled" pill when toggle on).
- **No-instructor session**: next Sunday morning CBT-125 at Belfast (red "Needs
  instructor" pill on the block).
- **Multi-instructor session**: next Sunday afternoon CBT-125 — Dave + Priya
  co-teach. Calendar lists "Dave, Priya".
- **CBT competencies** (5 DVSA elements A-E) seeded for both CBT-125 and CBT-650;
  **MOD 1 competencies** (slow-control) for ctPracMod1; existing MOD 2
  (on-road) for ctPracMod2. Test days stay non-teaching.
- More incidents (5), instructor earnings + payments spread across past month,
  bike maintenance expenses, instructor expenses at all status stages.

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
- **Audit trail UI — filter / search** — `audit_log` table records every
  authenticated mutation; admin sidebar surfaces `/admin/audit` with
  role-coloured actor pills + entity-stripe rows. Filtering by entity / actor /
  date range is on the wish-list; the read-only timeline is shipped.
- **Firebase App Check** — deferred. Would gate every API request on an
  attestation token proving the call came from the real Flutter app /
  trusted browser. Best defence against signup-flood / scripted-API
  abuse, on top of Firebase Auth's own per-IP throttles. Wiring is ~half
  a day: register providers per platform in the Firebase console, add
  `firebase_app_check` to the Flutter app, verify the `X-Firebase-AppCheck`
  header in `authMiddleware`. Roll out in monitor mode for a week before
  enforcing.
- **Stripe / online prepay** — plan phase 2
- **GPS history** — schema has the nullable fields; live map view deferred to
  phase 3
- **Real production deploy** — no Cloud Run / Cloudflare Pages config yet
- **Real user testing** — only API smoke + unit tests; UI testing is the next step
- **Multi-role user** — a user can hold only one role today; plan acknowledged
  this and we'd add a `user_roles` join table when a real use case appears

---

## Decisions made along the way (don't re-litigate)

- **Auth** — migrated to Firebase Auth 2026-06-08 (the deferred decision
  finally tripped its trigger: password reset). Backend dual-paths on
  token shape so the legacy session tokens still validate until
  `/auth/login` is deleted. See `firebase-auth-migration.md`. Originally:
  rolled-own (bcrypt + opaque session tokens). See
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
- [x] _Found 2026-06-11 (money safety):_
  `applyCancelWithApprovalInTx` (disruption-cancel path) wasn't voiding the
  auto-charge, so a school cancelling a disrupted booking left the student with
  a stuck charge for a session that never happened. Fixed: same `voidAutoCharge`
  call the regular `cancelInTx` uses, executed inside the disruption tx so it
  rolls back atomically if the cancel fails.
- [x] _Added 2026-06-11 (audit clarity):_ Post-session disruption cleanup used to
  reuse `cancel_with_approval`, which falsely implied the student got refunded
  and notified. Split into a new `dismissed` resolution (migration 0023, SQLite
  table rebuild to extend the CHECK constraint): no charge void, no notify,
  audit row reads "Dismissed past-due disruption row for …". Bulk
  `POST /disruptions/dismiss-past` mass-sweeps stale rows past their session
  end-time.
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

1. **UI testing** — actually drive each role in a browser. The 2026-06-11 sweep
   (master calendar interactivity, disruption candidate grid, dismiss/cancel
   split, signups Rejected tab, expense Web rebuild) added a lot of new
   surface area to click through. Focus on:
   - Master calendar: click-to-add at an empty slot, drag a session block to a
     new time, edit-session sheet (Roster add/remove/swap-bike, Free bikes Take
     offline, Cancel session), Show cancelled toggle on/off, per-status icons.
   - Disruptions: tap the past-due banner Dismiss all, tap a same-day
     cross-site amber tile (confirm dialog), tap a tile with the tight-from-prior
     pill, "None of these — cancel booking" path.
   - Sign-ups: reject → switch to Rejected tab → Restore.
   - Instructor session detail: report incident inline beside Assess, Take
     bike offline on a roster row, Open Assessment (the route fix), Paid in
     Full vs Outstanding tile.
   - Expenses on Web: add with a photo + with a PDF via file_picker.
2. **Production deploy** — pick a target (Cloud Run + Cloud SQL / Render / a Pi)
   and wire `KS_API_BASE_URL` accordingly. The Go server is a single static
   binary; the Flutter web build is `app/build/web/`.
3. **FCM** — set up a Firebase project, drop the config files, ask Claude to
   wire `firebase_messaging` + the Go dispatcher.
4. **Whatever surfaces from #1** — most likely small UI bugs once you click around.
