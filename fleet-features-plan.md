# Fleet features — implementation plan

**Status: ready to build.** Three sequential chunks. Each ships green and is independently revertable.

---

## Locked decisions

1. **Settings page is first.** Existing school settings get a UI; the page hosts the new warning thresholds the next chunk needs.
2. **Warning thresholds live on `schools`**, not on a sibling KV table. Concrete typed columns, school engine defaults when NULL.
3. **MOT / tax / mileage / registration live on `bikes`**, not a sibling document table. Same reason — small, scoped, fast to read.
4. **No DVLA API integration for v1.** Bike registration is a `TEXT` column; the gov.uk vehicle-enquiry URL handles verification on click. Manager updates our DB after verifying.
5. **Maintenance log is a sibling table** (`bike_expenses`), not a re-use of the instructor `expenses` table. Different domain — no approval flow, no instructor owner, scoped to a bike asset.
6. **Reuse what's already in place**: `filestore.Store`, `media.ProcessReceipt`, the inline 50×50 base64 thumb pattern, `cached_network_image`, `ReceiptThumbCell`, the role-access matrix tests.

---

## Chunk 1 — Admin Settings page

**Goal:** Single home for school config. Existing settings get a UI; warning thresholds for chunk 2 land in the same screen.

**Backend:**

- Migration `0008_school_warning_thresholds.up.sql`:
  - `schools.mot_warn_days INTEGER DEFAULT 90`
  - `schools.mot_urgent_days INTEGER DEFAULT 14`
  - `schools.tax_warn_days INTEGER DEFAULT 30`
  - `schools.tax_urgent_days INTEGER DEFAULT 7`
- `admin.SchoolSettings` struct gains the four fields.
- `GetSchoolSettings` reads them, `UpdateSchoolSettings` writes them.
- `PATCH /school` already pointer-fields based — new fields slot in.

**Flutter:**

- `lib/screens/admin_settings_screen.dart` — form, sections, single save at bottom.
- Sections: School profile · Onboarding · Booking policy · Fleet warnings.
- Sidebar entry "Settings" (gear icon), top of nav, route `/admin/settings`.
- Reuses `schoolSettingsProvider`; invalidates on save.

**Tests:**

- Go: new `auth_matrix_test.go` row for `GET /school` (any-authed) and `PATCH /school` (adminOwner) — already there.
- Flutter: new row in `router_access_matrix_test.dart` for `/admin/settings`.

---

## Chunk 2 — Bike state (MOT, tax, mileage, registration)

**Goal:** Manager sees current MOT/tax/mileage on every bike card with colour-coded urgency pills; can update via inline form; reg is a tappable gov.uk link.

**Backend:**

- Migration `0009_bike_state.up.sql`:
  - `bikes.registration TEXT`
  - `bikes.mot_expires_on TEXT` (`YYYY-MM-DD`)
  - `bikes.tax_expires_on TEXT`
  - `bikes.current_mileage_miles INTEGER`
- New `bike_mileage_log` table — `id, bike_id, miles, recorded_at, recorded_by, source` — for the audit trail and future charts.
- `admin.BikeRow` gains the four fields plus a computed `motStatus` / `taxStatus` (`unknown | ok | due_soon | due_urgent | expired`).
- Helpers in a new `internal/admin/bike_warnings.go`:
  - `MOTStatus(today, expiry, warnDays, urgentDays)` returns the bucket.
  - `TaxStatus(today, expiry, warnDays, urgentDays)` same shape.
- `PUT /bikes/{id}` body gains the four fields; engine validates ISO dates.
- New `POST /bikes/{id}/mileage` — `{ miles, source }` body, inserts a log row + updates the snapshot column.

**Flutter:**

- `Bike` model gains registration, motExpiresOn, motStatus, taxExpiresOn, taxStatus, currentMileageMiles.
- Bike card layout updates:
  - Reg pill (tappable → vehicle-enquiry gov.uk URL).
  - MOT pill (colour-coded by status, date inline).
  - Tax pill (same).
  - Mileage line.
  - "Update" affordance opens a sheet with date pickers + miles field.
- `lib/util/gov_links.dart` — `vehicleEnquiryUrl(reg)` and a secondary `motHistoryUrl(reg)` for the MOT update sheet.
- Filter pill on fleet page: "MOT due (N)".
- Sidebar fleet badge counts `due_urgent + expired` for both MOT and tax.

**Tests:**

- `internal/admin/bike_warnings_test.go` — table-driven for every bucket boundary.
- Auth matrix row for `POST /bikes/{id}/mileage` (staff per role gate — same level as other bike mutations).

---

## Chunk 3 — Bike maintenance log

**Goal:** Every quid spent on a bike is recorded with a receipt photo. Auto-record sheet appears when MOT/tax updated.

**Backend:**

- Migration `0010_bike_expenses.up.sql`:
  - `bike_expenses` table — `(id, school_id, bike_id, category, amount_pence, occurred_at, vendor, notes, receipt_storage_key, receipt_content_type, receipt_size_bytes, receipt_thumb, recorded_by, recorded_at)`.
  - Categories hardcoded — `parts | labour | mot | tax | service | other`.
- `internal/bikemaint/` engine package — `Record`, `List`, `Get`, `Delete`.
- HTTP routes (admin/owner):
  - `GET /bikes/{id}/expenses`
  - `POST /bikes/{id}/expenses` (multipart, same upload pipeline as `/me/expenses`)
  - `GET /bike-expenses/{id}/receipt`
  - `DELETE /bike-expenses/{id}`

**Flutter:**

- New `lib/screens/admin_bike_detail_screen.dart` — drillable from the fleet card. Header bike info, "Maintenance log" section, "+" to record.
- Fleet card gains a "£XYZ YTD" pill (computed from the maintenance list).
- When MOT/tax updated in the chunk-2 sheet, a follow-up sheet pre-fills the right category + amount + asks for the receipt.
- Reuses `ReceiptThumbCell` and `cached_network_image`.

**Tests:**

- Engine + HTTP suite.
- Auth matrix rows.
- Receipt model test extended for `BikeExpense.fromJson`.

**Seeded data:**

- 5–10 historical maintenance entries across the seed fleet so the detail page demos full.

---

## Sequencing

Build in order. Each chunk lands green and shippable on its own:

1. Settings → ~2 hr ✅
2. Bike state → ~4–6 hr (biggest chunk) ✅
3. Maintenance log → ~4–6 hr ✅

After each chunk: `go test ./...`, `flutter analyze`, `flutter test`, and a manual smoke-test against the dev stack.

---

## Chunk 4 (future) — DVLA API polling for automatic MOT + tax updates

**Goal:** stop relying on the manager to manually check and type in
the dates. A background worker polls DVLA daily for every bike with a
registration on file, and updates `bikes.mot_expires_on` /
`tax_expires_on` from the official source. The manual update sheet
from chunk 2 stays — it's the override for new bikes the worker
hasn't seen yet and for forcing a refresh on demand.

**Why deferred:**

- Needs an API key from DVLA (free, but requires registering an
  account at <https://register-for-mot-history-api.service.gov.uk/>).
  Holding off until someone has the credentials in hand.
- Chunk 2 covers the manual flow that schools need on day one, so we
  can ship without this and add it later without any UI churn.

**DVLA endpoints:**

| What | URL | Key needed |
|---|---|---|
| MOT history (incl. expiry) | `GET https://history.mot.api.gov.uk/v1/trade/vehicles/registration/{reg}` | yes — `x-api-key` header |
| Vehicle tax + base details (VES) | `GET https://driver-vehicle-licensing.api.gov.uk/vehicle-enquiry/v1/vehicles` (POST with `{ registrationNumber }`) | yes — separate key |

Both have generous free tiers (5k requests / day on MOT history at
time of writing). With ~10 bikes per school × one daily call per bike
= 10 calls / day per school. Plenty of headroom.

**Data:**

Migration `0011_bike_poll_log.up.sql`:

```sql
CREATE TABLE bike_poll_log (
    id              TEXT    PRIMARY KEY,
    school_id       TEXT    NOT NULL REFERENCES schools(id),
    bike_id         TEXT    NOT NULL REFERENCES bikes(id),
    checked_at      TEXT    NOT NULL,
    source          TEXT    NOT NULL,   -- 'mot' | 'tax'
    outcome         TEXT    NOT NULL,   -- 'updated' | 'unchanged' | 'no_record' | 'error'
    error_code      TEXT,
    mot_expires_on  TEXT,
    tax_expires_on  TEXT
);

CREATE INDEX bike_poll_log_bike_idx
    ON bike_poll_log(school_id, bike_id, checked_at DESC);
```

Plus on `bikes`: `last_polled_at TEXT` (snapshot of the most-recent
successful check, so the UI can say "checked 4 hours ago").

**Engine package — `internal/dvla/`:**

```go
type Client struct {
    motKey  string
    vesKey  string
    httpc   *http.Client
}

func (c *Client) FetchMOTExpiry(ctx, reg) (date, error)
func (c *Client) FetchTaxExpiry(ctx, reg) (date, error)
```

`Client` is nil when env vars aren't set — falls through to a no-op
worker, same pattern as the Firebase / GCS init.

**Worker:**

Mirrors `internal/reminders/`. Runs in the server process; ticks on a
configurable interval (default 24h, override via flag). On each tick:

1. List all bikes with non-empty registration.
2. For each bike, hit both DVLA endpoints with a 5-second timeout.
3. Compare returned dates with what's in the DB. If different,
   `UPDATE bikes ...` and append to `bike_poll_log`.
4. If the DVLA value differs from a recently-manually-edited value
   from the chunk-2 sheet, log a warning (the human entered something
   different — investigate, don't auto-overwrite).
5. Throttle: 1 request/second across all bikes, even if intervals
   stack up. The free tier is generous but we should be polite.

**Conflict handling:**

If the worker comes back with a date that disagrees with what a
manager manually typed within the last 7 days, **don't overwrite**.
Log it as `outcome='conflict'`, surface in the bike detail screen
("Manager said 2026-09-12, DVLA says 2026-09-19 — please verify").
This protects against typos and against DVLA's occasional staleness
after a fresh MOT.

**UI additions:**

- Bike detail page header: small "Auto-checked 4h ago via DVLA" line
  next to the MOT pill when `last_polled_at` is recent.
- Settings page section: "DVLA integration" — read-only "Connected /
  Not configured" status, link to docs on getting a key, manual
  "Refresh all bikes now" button.
- Bike detail history strip: the chunk-2 update sheet gains a
  "Recent checks" section listing the last 10 `bike_poll_log` rows.

**Config:**

```
DVLA_MOT_API_KEY=...
DVLA_VES_API_KEY=...
DVLA_POLL_INTERVAL=24h     # default
```

Server logs auth/storage modes on startup; same pattern for DVLA
(`dvla: enabled` / `dvla: disabled — set DVLA_MOT_API_KEY...`).

**Out of scope:**

- Backfilling historical MOT readings (the API does return history;
  we'd only need the current expiry).
- Tax payment dispatch — DVLA only tells us if it's paid; the
  manager still pays via the usual gov.uk flow.

**Effort:** ~6 hr including tests + worker harness. Not blocked by
anything, just waiting on the API keys.

