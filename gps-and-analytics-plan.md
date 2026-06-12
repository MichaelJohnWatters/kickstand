# GPS live map + Manager analytics — implementation plan

**Status: shipped 2026-06-12.** Chunk 1 (/admin/gps) and chunk 2
(/admin/analytics) both live. Chunk 2 deviated from the plan in one
way: revenue is **not** duplicated under analytics — it stays on
/admin/finance (already shipped), and the analytics page links to it
rather than re-rendering the same numbers. This keeps a single source
of truth for money UX.

The canonical plan in `motorbike-training-plan.md` covers GPS in §7 (MVP =
live snapshot view, history/playback deferred to phase 3) and analytics
in §8 phase 2/3 ("reporting/analytics", "deeper analytics"). This doc
turns those bullets into concrete chunks.

---

## Locked decisions

1. **Two separate pages.** `/admin/gps` (live map) and `/admin/analytics`
   (dashboard). They share nothing functionally and trying to combine
   them would just be a tab bar over two unrelated screens.
2. **GPS is presentational only.** Per plan §7, the scheduling /
   logistics engine never reads GPS — `current_location_id` stays the
   logical source of truth. The map is a status visualiser, nothing
   more. Plot bikes from `last_known_lat/lng/at` snapshot fields only.
3. **Tracker source is provider-agnostic.** A single `POST /bikes/{id}/gps`
   endpoint accepts `{ lat, lng }` from whatever the school wires up
   (real tracker webhook, mobile app, manual update). We never ship a
   vendor integration.
4. **flutter_map + OpenStreetMap tiles.** No API key, no billing, works
   on web + mobile + desktop. Mapbox/Google Maps are nicer but cost
   money and add a credential to manage — unjustified for a snapshot
   view. Attribution required (OSM) — single line in the map corner.
5. **15-second polling for live updates.** Same cadence as the
   notification bell. Real websocket "live" is phase 3 alongside the
   route-playback work.
6. **Analytics queries run direct against SQLite each request.** No
   materialised views, no caching layer. SQLite handles the load
   trivially at this scale; we can add caching once we measure it.
7. **`fl_chart` for charts.** Pure-Dart, no native deps, works on web.
   Already maintained, ~3MB to the bundle uncompressed.
8. **Default date range: last 30 days.** Presets for 7d / 30d / 90d /
   YTD. Custom ranges via two date pickers. Range applies to all four
   sections on the analytics page; no per-card override (avoid the
   "why does this number disagree with that one" UX trap).

---

## Chunk 1 — GPS live map

**Goal:** Single manager page showing every bike as a marker on a map of
Northern Ireland. Colour by status, "last seen" pill, tap → bike detail.
Schools with no trackers see "no signal" placeholders and the page is
honest about it rather than hiding empty.

**Backend:**

- Migration `0026_bike_gps_timestamp.up.sql`:
  - `bikes.last_known_at TEXT` (ISO8601 UTC) — completes the trio the
    plan §7 called for; `last_known_lat` + `last_known_lng` are already
    in 0001.
- `internal/admin/bike_gps.go`:
  - `UpdateBikeGPS(ctx, scope, bikeID, lat, lng)` — validates ranges
    (-90/90, -180/180), stamps `last_known_at = now()`, writes audit
    row (`bike.gps_updated`).
  - `ListBikeGPS(ctx, scope) []BikeGPSRow` — single SELECT joining
    `bikes` + `locations` + the current session (if any) so each row
    carries: id, nickname, registration, current location id + name,
    status (`available` / `in_session` / `offline` / `needs_attention`),
    last_known_lat/lng/at.
- HTTP:
  - `POST /bikes/{id}/gps` — admin/owner only, body `{ lat, lng }`,
    returns 204.
  - `GET /admin/bikes/gps` — admin/owner only, returns the row array.
- No new package — slot into `internal/admin`.

**Flutter:**

- Add `flutter_map` + `latlong2` to `app/pubspec.yaml`.
- New `app/lib/screens/admin_gps_map_screen.dart`:
  - Full-screen `FlutterMap` with OSM tile layer, attribution line
    bottom-right.
  - Initial centre: NI centroid (54.6°N, -6.5°W), zoom 9 — fits
    Belfast/Lisburn/Newry comfortably.
  - Markers from `GET /admin/bikes/gps`, polled every 15s.
  - Marker style: 28×28 circle, fill = status colour
    (`available` green / `in_session` indigo / `offline` red /
    `needs_attention` amber), 2px white ring. Bike nickname label
    below at zoom ≥ 11.
  - Bikes with no GPS data render in an off-map "No signal · N bikes"
    panel pinned bottom-left.
  - Tap a marker → bottom sheet with bike nickname, reg (mono),
    current location, "last seen 4 min ago" pill (>24h shows grey
    "stale" pill), "View bike detail →" button to
    `/admin/bikes/:id`.
- New `app/lib/util/bike_status.dart` — `BikeStatus` enum + colour /
  label helpers, reused by the marker and the no-signal panel.
- Sidebar entry "Live map" with `Icons.my_location`, slot it next to
  "Logistics" since they're both physical-world admin views.
- Router entry `/admin/gps` in `app/lib/routing/router.dart`.

**Tests:**

- `internal/admin/bike_gps_test.go` — table-driven coordinate
  validation, audit row written, returned-row shape.
- Auth matrix row for `POST /bikes/{id}/gps` (adminOwner) and
  `GET /admin/bikes/gps` (adminOwner).
- `app/test/router_access_matrix_test.dart` — new row for
  `/admin/gps` (adminOwner).

**Seed:**

- Lagan Valley's 7 bikes get realistic starting coords at their home
  location (Belfast / Lisburn / Newry) with ±100m random offset, and
  `last_known_at` = seed run time. No live jitter — the demo is honest
  about the snapshot semantics.

**Demo-mode hook:**

- `MockApiClient._send` lookup gets `/admin/bikes/gps` → static dump
  in `app/assets/demo/bike_gps.json`. Add to `scripts/dump-demo.sh`.

**Effort:** ~half a day. Map UI is the unknown — flutter_map is
straightforward but the marker overlay layout has fiddly bits.

---

## Chunk 2 — Manager analytics dashboard

**Goal:** A single page that answers four questions an owner actually
asks: "Are my bikes earning their keep?" / "Who's pulling weight?" /
"How's revenue tracking?" / "Are students getting through the funnel?"

**Backend:**

New package `internal/analytics`. Each function takes
`(ctx, scope, from, to time.Time)` and returns a typed DTO. All four
are pure reads — no mutations, no events, no audit.

1. **`BikeUtilisation(scope, from, to) []BikeUtilisationRow`**
   - Per bike: `bikeID, nickname, registration, bookedHours,
     availableHours, utilisationPct, sessionsCount, lastSession`.
   - Booked = sum of `sessions.duration_minutes` for sessions where
     the bike is assigned to a non-cancelled booking, in range.
   - Available = (date range × instructor recurring availability
     hours / 7) per location the bike could plausibly serve — for
     v1, simplify to (range days × 8h) per bike. Refine when the
     simple model lies.
   - SQL: one CTE per bike, sum from `bookings` × `sessions`.

2. **`InstructorUtilisation(scope, from, to) []InstructorUtilisationRow`**
   - Per instructor: `instructorID, name, sessionsTaught, hoursTaught,
     earnedPence, paidPence, outstandingPence, weeklyTrend []int`.
   - earned / paid pulled from `instructor_earnings` +
     `instructor_payments` (already exists).
   - weeklyTrend = 8 buckets of sessions/week, ending at `to`. For
     the sparkline.

3. **`RevenueSummary(scope, from, to) RevenueSummary`**
   - Totals: `chargedPence, paidPence, outstandingPence,
     monthlySeries [](month, charged, paid), agedDebt
     (bucket0_30, bucket31_60, bucket60Plus)`.
   - Pulls from `student_charges` + `student_payments`.

4. **`Funnel(scope, from, to) FunnelStats`**
   - `signupToFirstBookingPct` — of signups in range, % with ≥1
     non-cancelled booking within 30 days.
   - `cbtCompletionPct`, `theoryPassPct`, `practicalPassPct` —
     derived from `external_tests` + booking completions.
   - `perInstructorPassRate []{ instructorID, name, pct, attempts }`.

HTTP — admin/owner only:

- `GET /admin/analytics/bike-utilisation?from=&to=`
- `GET /admin/analytics/instructor-utilisation?from=&to=`
- `GET /admin/analytics/revenue?from=&to=`
- `GET /admin/analytics/funnel?from=&to=`

Single mounted handler that dispatches by path suffix is fine.
Defaults: if `from`/`to` missing, last 30 days from now.

**Flutter:**

- Add `fl_chart` to `app/pubspec.yaml`.
- New `app/lib/screens/admin_analytics_screen.dart`:
  - Header: title + date-range picker (preset chips + custom range
    button) + Refresh action.
  - Four cards, each a section, in this order:
    1. **Revenue** (top — money is the headline) — three big numbers
       (charged / paid / outstanding), a 6-month bar chart by month,
       three aged-debt buckets.
    2. **Bike utilisation** — sortable table (nickname, sessions,
       hours, % util, last session). Heatmap-style colour on % column.
    3. **Instructor utilisation** — table with sparkline column for
       weekly trend, totals row at bottom.
    4. **Funnel** — three stat tiles for CBT / theory / practical
       completion %, signup→first-booking %, per-instructor pass rate
       table.
  - Loading state per section (don't block the whole page on one slow
    query).
  - Empty state per section ("No bookings in this range" rather than
    silent 0s).
- Sidebar entry "Analytics" with `Icons.insights`, near the top
  (manager dashboards belong near Overview).
- Router entry `/admin/analytics`.
- Reuses `schoolSettingsProvider` for the currency symbol.

**Tests:**

- `internal/analytics/*_test.go` — table-driven fixtures per function.
  Empty range, single bike/instructor, partial month boundaries are
  the interesting cases.
- Auth matrix rows for all four endpoints.
- `app/test/router_access_matrix_test.dart` — row for `/admin/analytics`.

**Seed:**

- The existing seed already gives enough data for analytics to render
  non-trivially (bulk calendar fill ± 2 weeks, payments + earnings
  spread, mixed test outcomes). No new seed needed.

**Demo-mode hook:**

- `MockApiClient._send` covers four endpoints → four static dumps in
  `app/assets/demo/analytics_*.json`. Added to `scripts/dump-demo.sh`.

**Effort:** ~1.5 days. The four queries are individually small but the
test fixtures take real time, and chart UI polish always wins back the
estimate.

---

## Sequencing

Build in order. Each lands green and shippable on its own:

1. GPS live map — ~half day.
2. Manager analytics dashboard — ~1.5 days.

After each chunk: `go test ./...`, `flutter analyze`, `flutter test`, and
a manual smoke through Owen's admin.

---

## Out of scope (for this plan)

Per plan §7 phase 3 and a deliberate scope discipline:

- **GPS time-series history / route playback** — needs a `bike_gps_log`
  table, retention policy, playback UI. Big build, deferred.
- **Geofencing / theft alerts** — phase 3 with a rules engine + notify
  hook.
- **Mileage from GPS** — phase 3 (the chunk-2 mileage column is manual
  entry only; DVLA polling is the auto-source candidate).
- **Real-time websocket map updates** — 15s polling is the v1 cadence.
- **Mapbox / Google Maps** — wouldn't enable any feature we don't
  already get from OSM; revisit only if visual polish becomes a sales
  blocker.
- **CSV / Excel export** of analytics — flag for v2 if a school asks.
- **Cross-school franchise reporting** — phase 3 multi-tenant aggregate
  view, not relevant until there's more than one school.
- **Per-card date range override** — deliberately one range for the
  whole page (numbers must agree).
- **Caching / materialised views** for analytics — add when SQLite shows
  it can't keep up at school scale, not before.

---

## Risks + mitigations

- **`flutter_map` web rendering quirks.** OSM tiles work on web but the
  marker layer has had clipping bugs in older versions. Mitigation: pin
  to the latest stable; smoke-test the demo build before declaring
  done.
- **OSM rate limits.** OSM's public tile server has fair-use limits
  (~10 r/s). One school of staff hitting the map is well under the
  threshold, but a viral marketing demo could trip it. Mitigation: if
  it becomes real, add a Mapbox token as an opt-in env var (no code
  fork — flutter_map's tile-layer URL is just a config string).
- **Coordinate validation on the write endpoint.** Bad client data
  could silently park bikes in the Atlantic. Mitigation: range check +
  reject coords more than 200km from any of the school's
  `locations.lat/lng` (warn-not-reject in v1; can tighten later).
- **Analytics queries get slow as data grows.** Each query is O(N
  bookings) for typical workloads. Mitigation: index check before
  shipping; the queries the plan assumes (date-range filter on
  `bookings.starts_at`, joins to small dimension tables) are
  index-friendly. If a query exceeds 200ms at demo scale, add the
  index in the same chunk, not later.
- **Bike status mapping for the map markers.** "in session" is derived
  state — sessions that are starts_at ≤ now ≤ ends_at. Cheap to compute
  on read, no new column needed. Mitigation: helper in
  `internal/admin/bike_gps.go`, single source of truth.
