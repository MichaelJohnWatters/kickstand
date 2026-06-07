# Motorbike Training Management Platform — Build Plan

A multi-tenant SaaS for UK motorcycle training schools. Instructors and students manage and view training progress; management handles instructor availability, bike fleet, multi-location logistics, scheduling, student records, and a manual payment ledger. Sold to many schools (multi-tenant from day one). No automated card processing in the MVP — money is tracked via a manual ledger (cash / bank transfer / card-in-person recorded by admin).

---

## 1. Product summary

**Who uses it**
- **Students** — book/cancel/reschedule training sessions, see their progress and upcoming bookings, manage their licence details.
- **Instructors** — set availability, view their schedule, record attendance and assess student progress.
- **Admin / Owner (school management)** — manage instructors, bike fleet, locations, course definitions; view the master calendar; resolve disruptions; see daily bike-logistics summaries.

**UK training context — region-specific (important: NI ≠ GB)**

The licensing pathway differs by region, so **the course/test structure must be configurable per region/school, not hardcoded.** Two regions to support:

**Northern Ireland (initial target):**
- Path: provisional licence → **CBT** → theory test → **practical test**. NI does **not** use the GB "Mod 1 / Mod 2" naming.
- **CBT is parameterised by bike category/age**, not a single course. Roughly: A1 (17–19) does CBT on a **125cc**; A2 (19+) on a **larger ~500/600/650cc** machine; A (24+) on a 600cc. This is the user's "125 CBT vs 650 CBT" — model it as **CBT course variants linked to a required bike category** (small/125-class vs large/500–650-class), not one fixed CBT.
- CBT bike size ≠ solo entitlement: an A2 learner who did CBT on a large bike may still only ride a 125 **unaccompanied**, and needs a **DVA-approved instructor present** to ride bigger. This accompaniment rule is an NI-specific constraint the booking/eligibility logic may need later.
- CBT certificate valid 2 years.

**Great Britain (later expansion):**
- Path uses **CBT → Mod 1 (off-road manoeuvres) → Mod 2 (on-road)**, Mod 1/2 booked with DVSA. Requires theory passed before Mod 1.

**Shared across regions:** the progressive licence categories (**AM / A1 ≤125cc·11kW / A2 ≤35kW·47bhp / A unrestricted**) with their age limits are common; what differs is the **test/course structure and naming**. Also note CBT may **not** transfer between NI and GB — treat CBT validity as potentially region-specific if you expand.

**Design consequence:** `course_types` (already per-school) must express region-specific pathways and **CBT-by-bike-category variants**; the required bike category links the course type to the fleet. Don't bake GB's Mod 1/Mod 2 in as universal.

Key consequence (unchanged): the platform books **training sessions**; in GB some relate to **external DVSA test dates** the school doesn't control (recorded for reference/reminders, owned outside the system). NI practical/theory tests are likewise externally booked.

---

## 2. Architecture decisions (already settled)

| Area | Decision | Why |
|------|----------|-----|
| Multi-tenancy | Shared database, row-level isolation. Every table carries `school_id`. | Standard SaaS approach; cheap, scales to many schools. |
| Tenant isolation | Postgres **Row-Level Security (RLS)** — DB enforces "you only see your school's rows". | Protects against an app bug leaking one school's data to another. |
| Database | **PostgreSQL** (not Firestore, not SQLite). | Domain is strongly relational and transaction-heavy; the booking engine needs real joins + atomic transactions. |
| Suggested backend | **Supabase** (Postgres + auth + RLS + realtime, batteries included). | Gives the "Firebase convenience" originally wanted, but on a real relational DB. |
| Clients | **Flutter** for iOS + Android native apps (app-store presence is a selling point for schools). Web served via Flutter Web for logged-in app-in-browser use; a lightweight separate marketing site can come later. | One codebase for mobile; store listing gives schools the "real app" credibility they want. PWA was considered and rejected for this reason. |
| Payments | **Manual ledger in MVP** (charges + payments + derived balance). No card processing / Stripe yet. | Schools take cash / bank transfer / card-in-person; they need to track "owes £50", not process cards. Stripe slots in later as just another payment method. |
| Per-school config | Course types, ratios, durations, pricing, cancellation policies, cross-site move rules are all **per-school settings**, not global constants. | Schools run things differently — don't hardcode. |

**Behavioural rules chosen (affect booking logic, not table structure):**
- **Bike location auto-updates** to wherever its last completed session left it, with a manual "send home" override. *(Leaning — confirm.)*
- **"Any" bike auto-assigns** a suitable free bike atomically at booking time. *(Leaning — confirm.)*
- A **disrupted booking awaiting manager approval holds the slot** for the student (not released). *(Leaning — confirm.)*

---

## 3. Data model

### Tenancy & people
- **schools** — the tenant. Everything FKs back to this.
- **users** — anyone who logs in. Has `school_id` + `role` (student / instructor / admin / owner). One table with roles; a person can hold more than one role. Includes **phone number** (captured at signup) — staff-visible only (instructors + admin, never other students), used for operational contact, the manager's approval call, and as the **SMS channel** when reminders arrive (phase 2). Collected with a clear purpose (operational contact) per UK GDPR. Students also carry an **`account_status`** (active / pending-approval) for the onboarding flow below.
- **student_profiles** — provisional licence info, CBT certificate + expiry (+ which CBT variant / bike category, and region), theory test pass date (gates progression where required), transmission preference (auto/manual — note: doing CBT on an automatic can require repeating it to switch to geared, so this matters), licence category pursued (AM/A1/A2/A) and rider age (drives which CBT variant + accompaniment rules apply).
- **instructor_profiles** — course types qualified to teach, certifications, optional home location.

### Student onboarding (per-school toggle)
Students **self-sign-up** (phone number captured at signup). Each school chooses, via a **per-school setting**, how new sign-ups are handled:
- **Open booking** — sign up → book immediately. Frictionless; suits high-volume schools.
- **Approval required** — sign up → `pending-approval` → manager reviews (has the phone number to ring them for a chat) → approves → can book. Suits cautious/smaller schools; doubles as a light safeguarding/quality lever (e.g. catch age/intent before any booking exists).
- **Pending users default to browse-but-not-book** — they can log in, see availability and a "pending approval" state, but can't confirm a slot until approved (warmer than a hard wall; keeps keen students engaged). Keep it to one toggle — don't over-complicate with a separate hard-gate option unless asked.

### Resources
- **locations** — a school's training sites (per school).
- **bikes** — fleet. Category (A1/A2/A), transmission (manual/auto), engine size, registration, status, `home_location_id`, `current_location_id`, plus **nullable** `last_known_lat` / `last_known_lng` / `last_known_at` (optional GPS).
- **bike_unavailability** — date/time ranges a bike is out, with a reason (at mechanic, damaged, broken, off-road). Start can be "now" for mid-day breakages. Separate from bookings.

### Scheduling (the heart of the system)
- **course_types** — per-school, **region-aware** definitions of the pathway steps (NI: CBT-variants + practical; GB: CBT / Mod 1 prep / Mod 2 prep). Each carries default duration, max student:instructor ratio, **required bike category** (e.g. CBT-125 vs CBT-500/650), eligibility prerequisites, and a **`non_teaching` flag**. CBT is modelled as **variants tied to bike category/age**, not one fixed course. **Test days are also course types** (see below).
- **availability** — when an instructor offers time (recurring or one-off blocks); also covers instructor time off.
- **sessions** — a bookable session: links a `course_type`, `instructor`, date/time, **capacity**, and a **location** (where it runs). One CBT day = one session with capacity N.
- **bookings** — a student's place in a session (the student↔session join). Optionally references a specific **bike** (nullable; auto-assigned or admin-assigned). Status: booked / completed / no-show / cancelled / **needs_reassignment (disrupted)**. Also `cancelled_by` and `cancellation_reason` to distinguish student cancels from blameless school-initiated cancels.
- **test days = a non-teaching course type** (e.g. "TEST MOD 1"). Rather than a separate booking concept, a test day is just a **course type with `non_teaching: true`** — it reuses sessions/bookings/bikes/locations/ledger exactly like any other course. The flag tells the system **not** to prompt for competency assessment or treat it as a lesson, while still reserving bike (± instructor escort), carrying a **location** (so logistics flags "this bike needs to be in Lisburn tomorrow"), and **charging** via a normal ledger charge. Links to the relevant `external_tests` row.
  - **One-or-many sessions = the flexibility:** the course type is the reusable template; how it's instantiated handles real-world test days. Parallel/identical tests → **one session, capacity N** (reserve N bikes). Back-to-back staggered tests (different times/bikes/centres) → **N separate single sessions**. Same template, per-day choice — no model change needed for either.
  - **No test-centre addresses / DVA integration / routing** — the school knows where the test is; the session just needs a location to tie the bike to.

### Progress
- **competencies** — per-course-type checklist items (e.g. U-turn, emergency stop). Not applicable to `non_teaching` course types (test days).
- **progress_records** — instructor's assessment of a student against competencies per session, plus free-text notes. **Skipped for `non_teaching` sessions** (a test day reserves bike/instructor and charges, but has no assessment to capture).

### Disruption & external
- **disruptions** — one bike-down event linked to the bookings it affected and how each resolved (swap / cancel / pending). Manager view + audit trail.
- **external_tests** (was "dvsa_tests") — per student, per test, externally booked: date, reference, **outcome (pass / fail / not-yet)**, **attempt number** (multiple rows = multiple attempts). Test *types are region-specific*: GB = Mod 1 / Mod 2; NI = theory + practical. CBT is completion-based, not pass/fail — model its repeats as "completed / needs return day", distinct from the pass/fail tests.

### Incidents & student records (new)
- **incidents** — a damage/incident event, optionally linking the **student** who was riding, the bike, and notes. Distinct from `bike_unavailability` (which is the bike going offline); an incident *may* trigger an unavailability. Sensitive data — staff-visible only.
- **student_notes** — split into two kinds:
  - **safety/accommodation flags** — structured, actionable, surfaced prominently to the next instructor (e.g. "requires low-seat bike", "build up roundabouts slowly").
  - **progress notes** — free-text running commentary.
  - Both are **staff-visible only (instructors + admin), never the student**, enforced by RLS at the data layer — not just hidden in the UI. Treat as UK GDPR personal data: notes must be professional, factual, defensible (a Subject Access Request can expose them). UI should nudge toward factual phrasing.

### Payment ledger (new)
- **charges** — a cost a student incurred (e.g. "CBT day £130"), ideally linked to the booking that caused it. **MVP: created manually by admin.** (Auto-on-booking was considered but deferred — prepay in phase 2 makes the charge coincide with online payment, so auto-charge-at-booking would be partly reworked anyway.)
- **payments** — money received: amount, **method (cash / bank transfer / card-in-person / other)**, date, recorded-by.
- **Balance is derived** (sum of charges − sum of payments), never a hand-edited field. "Owes £50" and paid/part-paid/unpaid status all fall out of the derived balance, with full dated history for disputes. No card processing / PCI scope; Stripe (phase 2) would just be another payment method feeding the same ledger.
- **Who can do what (per-action permissions):** **recording a payment** is frequent and field-based — instructors are often the collection point (e.g. £130 cash on the morning of a CBT), so **instructors can record payments** (amount + method + recorded-by = them), gated by a **per-school toggle "instructors can record payments" (default on)** for control-conscious owners. **Adjusting/voiding a payment, and creating/editing/deleting a charge, stay admin-only** — rarer, less time-sensitive, and where errors do damage. The **`recorded-by` field is the safeguard** that makes broader recording access accountable (ties into the deferred audit trail).
- **Instructors need a minimal money view, not the full ledger:** if they take payments they need a light **"amount outstanding + record payment"** panel on their session/student view — not the full manager financial screen (charge history etc. stays admin).

### Instructor pay — parallel ledger (new)
Money flowing **out** to instructors — a mirror of the student ledger, opposite direction, different inputs. **Kept separate from student charges/payments** (different party, different calculation basis).

- **instructor pay model** — stored **per instructor** (schools run a mix), with a `pay_basis`:
  - **percentage** (of the session's student revenue) — *the common case for freelance instructors*
  - **per day / per session** (flat)
  - **per hour**
  - **per student**
  - **salary / N/A** (employed — not tracked here)
  - Carries the relevant rate/percentage value; **optionally overridable per course type** (a Mod 2 escort day may pay differently from a CBT day).
- **instructor_earnings** — what an instructor accrued, generated from a **completed session**. **MVP: entered manually by admin** (consistent with charges; auto-calculation deferred). For **percentage** earnings, the record should **reference the session and the charges it derived from**, not just a bare number — so the later automation is clean and "how was this calculated?" is answerable.
- **instructor_payments** — what the school has actually paid the instructor.
- **Balance derived** (earnings − payments) → "we owe Dave £340."

> **Dependency to note:** percentage earnings are calculated *from the student ledger* (the charges for that session). This is why manual-first is sensible (the charge must exist and be correct first) and why the earning references its source charges.

> **Scope guardrail: this is owed-tracking, NOT payroll.** No payslips, PAYE, NI, or tax handling — that's regulated and schools use an accountant / payroll software. This feature feeds that, it doesn't replace it.

### Confirmed modelling choices
- **CBT = one session, capacity N, N bookings** (capacity model, not N separate sessions).
- **Bike lives on the `booking`, not the `session`** (each CBT student needs their own bike; for 1:1 it's equivalent).

---

## 4. The booking constraint engine (core logic)

A booking is valid only when **all** of these hold simultaneously, checked inside a single DB transaction to prevent two people grabbing the last slot/bike:

1. **Instructor** is available for that time and qualified for the course type.
2. **Bike** is suitable (right category + transmission), not in `bike_unavailability`, not double-booked, and either at the session's location or able to be moved there in time.
3. **Student** is eligible per the course type's prerequisites (region-specific — e.g. NI: valid CBT of the right variant before practical training, theory passed where required; GB: theory passed before Mod 1, valid CBT before Mod tests). May later need to encode the NI **accompaniment** rule (rider can only solo-ride up to their entitlement; larger bikes require an instructor present).
4. **Capacity** isn't exceeded — *and* a suitable bike is actually free. Real bookable limit = `min(capacity, suitable free bikes)`.

The same matching logic ("suitable, free, right location") runs **reactively** when a bike breaks — to find a swap candidate for already-booked sessions.

**Scope boundary — no licensing-rules engine.** The system does **not** encode/enforce licensing law (age thresholds, progressive-access timings, CBT-validity gating). That's the DVA/DVSA's job and the school's professional judgement — encoding it is a compliance liability and the rules change. Course types stay **generic** (CBT / Mod 1 / Mod 2 or the NI variants). **Upgrades and retakes are just ordinary new bookings + new `external_tests` rows** — no progression state-machine. The system *records the facts* (category pursued, CBT variant + expiry, test outcomes) and at most offers **soft, non-blocking advisory prompts** (e.g. "⚠ CBT expires before this session") — consistent with the warn-don't-block pattern used elsewhere. It never gates what someone may book.

---

## 5. Locations & bike logistics

- Sessions happen **at** a location; bikes have a home + current location.
- When a bike's current location ≠ a booked session's location, that bike needs moving.
- **End-of-day logistics summary** is a *derived query/view*, not stored data: compare assigned bikes' current locations against tomorrow's sessions' locations, grouped by destination — e.g. "Lisburn needs: bike A (from Belfast), bike C (from Newry)."
- MVP keeps logistics simple: surface the mismatch, let a human move the bike. A per-school "cross-site moves allowed with X hours notice" flag is enough — don't model transport time precisely.

### Instructor travel between sites (assistive warning)
Instructors can work multiple sites in a day (Belfast morning, Lisburn afternoon) — but can't teleport. The system **warns** when a schedule gives unrealistic travel time between consecutive sessions at different locations.

- **Scope: assistive only.** Scheduling sanity is the **manager's common-sense call** — the system never blocks, it just flags the obvious "that can't be right" cases so the manager isn't flying blind. The matrix is a prompt for attention, not an authority, so it needn't be minute-accurate.
- **location travel-time matrix** (per school) — approximate minutes between each pair of locations; one-time admin setup (most schools have few sites). **Reused by bike logistics too** — same matrix answers "can this bike reach the other site in time?"
- **Feasibility check** — for any two consecutive sessions at different locations, is the gap ≥ travel time + buffer? If not, show a non-blocking warning ("⚠ tight: 30 min to travel Belfast→Lisburn, usually ~40"). It's a check/warning, not stored data.
- **Per-school buffer** setting (default ~15 min) for parking/setup — "exactly the drive time" is itself unrealistic.
- Surfaced in the **master calendar and booking flow**. Consistent with the system-wide pattern: **the engine surfaces conflicts honestly; humans resolve them** (same as bike-aware capacity, logistics, and disruptions).

---

## 6. Disruption handling (bike breaks mid-day)

Two separate things:
1. **Take the bike offline** — a `bike_unavailability` row starting "now" with reason damaged/broken. Stops it appearing in future availability immediately.
2. **Resolve already-assigned bookings** from the breakage forward — a workflow with three outcomes:
   - **Swap** — reassign a suitable free bike (can be auto-suggested). Happy path.
   - **Cancel pending manager approval** — if no suitable bike; blameless, needs an approval step, slot **held** for the student.
   - **Pending** — sits in `needs_reassignment` until a human acts.

A `disruptions` record links the bike-down event to affected bookings for a single manager screen + audit trail.

---

## 7. Optional GPS layer

- Trackers are **optional** and per-school; most schools won't have them.
- The scheduling/logistics engine **never reads GPS** — it runs on the logical `current_location_id` only.
- MVP: three nullable fields on `bikes` (`last_known_lat/lng/at`) for a "live map" view where trackers exist.
- Deferred (phase 3): time-series location history, route playback, geofencing, theft alerts, mileage. Documented, not built.

---

## 8. Feature scope by phase

**MVP — Student**
- Browse/book slots filtered by course type (region-specific — NI: CBT variants + practical; GB: CBT / Mod 1 / Mod 2)
- Optionally select a specific bike, or "any"
- Cancel / reschedule (with per-school cancellation cutoff)
- See progress, history, upcoming bookings
- Manage licence info (provisional, CBT expiry, theory pass)

**MVP — Instructor**
- Day/week schedule view
- Set availability
- Mark attendance, record session notes + assess competencies

**MVP — Admin / Owner**
- Manage instructors + availability
- Manage bike fleet + mark bikes unavailable (date ranges, reasons)
- Manage locations
- Define course types (durations, ratios, required bike category, prerequisites)
- Master calendar (all instructors, bikes, bookings)
- Resolve disruptions (swap / cancel-with-approval)
- End-of-day bike logistics summary
- Set student onboarding mode (open booking vs approval-required) + **pending sign-ups queue** (review, phone, approve/reject)

**Phase 2**
- Payments & **online prepay** (Stripe — student selects a course, is charged, and pays online; the charge then coincides with payment and feeds the same ledger), notifications/reminders (email/SMS/push — big for reducing no-shows), waitlists, reporting/analytics, DVSA test-date reminders.

**Phase 3**
- GPS history & geofencing, multi-school franchise reporting, deeper analytics.

### Demo / preview (sales)
- **Launch approach: host the Claude Design mock-ups as a clickable "preview"** — serves as the early landing page *and* the design reference. Low effort: the mock-ups are already web-renderable, so this is just hosting them (ideally stitched for screen-to-screen clicking). No backend, no data, no second codebase.
- **Visual preview, not a functioning demo** — buttons won't do real work. Label it clearly ("Preview") so prospects don't expect a live product and hit dead ends.
- **Snapshot with a shelf life** — fine while pre-launch (the mocks are the freshest artifact); post-launch, refresh them or replace with real screenshots.
- **Keep it on a separate domain/path from the real app** (no login confusion).
- **Post-launch upgrade path** (deliberately *not* now): real screenshots/walkthrough, then a **seeded demo tenant** — just another `school_id` in the multi-tenant DB, pre-loaded with fake data, read-only/auto-reset. Nearly free given the existing architecture; it's the genuine app so it never drifts. **Avoid building a separate demo codebase** — that's a maintenance tax and a worse demo.

---

## 8b. Notifications & communication

### Notifications — an event-driven layer
Treat notifications as a **layer that listens to events**, not inline message-sending. App logic just records "booking created / session tomorrow / bike broke / payment overdue"; the notification layer decides who to tell and how. Use an **events/notifications table** (log of what was sent, retry on failure, add channels without touching booking logic) rather than firing messages from scattered code.

**Who gets what (maps onto events the system already emits):**
- **Students** (reminder-focused — directly attacks the no-show / lost-revenue problem): booking confirmation; **session reminder** (24h and/or 2h before — the high-value one); cancel/reschedule confirmation; disruption notice ("bike swapped" / "we need to rearrange"); CBT-expiry-approaching & "eligible to book Mod 1 now" (retention); payment reminder ("£50 outstanding").
- **Instructors**: new/cancelled booking on their schedule; morning daily-schedule summary (incl. tight cross-site travel flags); disruption affecting their session.
- **Managers**: disruption needing approval; end-of-day bike-logistics summary; (later) low bike availability, overdue payments, repeated test failures.

**Channels:** **email + push in MVP** (Flutter native push is more reliable than a PWA's would have been — part of why Flutter was chosen). **SMS deferred to phase 2** — most effective for reminders but costs per message + needs a provider (Twilio etc.); uses the phone number on the user record.

**Controls:** per-user **preferences** (channel + category, separating routine "reminders" from urgent "issues" so people don't mute everything and miss the important alerts) and **quiet hours / sensible send-times** (a 2am reminder feels broken; respect school operating hours).

**Scope split:**
- **MVP thin slice** (table-stakes — a booking with no confirmation/reminder feels broken): booking confirmation + session reminder (email/push) + manager disruption-approval alert. Plus the events table foundation.
- **Phase 2**: SMS, full preference centre, daily digests, retention nudges (CBT expiry, eligibility), payment reminders.

### Communication — the ladder (chat deferred but planned)
Reaching students is handled in rungs, cheapest first:
1. **Phone number + click-to-call/text** (MVP) — staff use their own dialer. Zero infra; solves most "I need to reach this student." Phone is on the user record, staff-visible only.
2. **One-way notifications** (MVP) — disruption/reminder notices are the school→student channel for what matters; no support-obligation trap.
3. **Structured two-way messaging tied to a booking** (phase 2) — "messages about this session", more contained/moderatable than an open inbox.
4. **Full real-time chat** (**deferred but planned — phase 3**) — see constraints below.

**Chat: deferred but planned.** When built, it must account for:
- **Real-time infrastructure** — live delivery, unread counts, presence (Supabase realtime helps, but it's a real build vs. the CRUD elsewhere). Couples tightly to the notification layer ("new message" pings).
- **⚠ Safeguarding — minors.** Schools train under-18s (CBT). A hosted messaging channel between an adult instructor and a minor student carries a **duty of care**: conversations must be **logged and manager-visible**, with safeguarding oversight designed in **before** any student↔instructor channel ships. This is the reason chat is not a casual add-on.
- **Responsiveness expectation** — a visible chat box implies someone's reading it; unanswered messages are worse than no chat. Needs a support model.
- **Foundations to lay now so later chat is clean:** the events/notifications layer and the staff-visible-only contact pattern already point the right way; don't build anything that assumes student↔student visibility.

---

## 9. Open decisions to confirm before build

**Settled since last revision:**
- ~~Platform~~ → **Flutter** native apps + Flutter Web (app-store presence wanted).
- ~~Money~~ → **Manual ledger in MVP** (charges + payments + derived balance).
- ~~Charges~~ → **Created manually by admin in MVP.** Auto-creation/prepay deferred to phase 2.
- ~~Marketing site / demo~~ → **Host the Claude Design mock-ups as a clickable "preview" landing page** for now (see Demo / preview above). Richer marketing site / seeded demo tenant deferred.

**Still to confirm:**
1. **Bike location** — auto-update to last session's location (leaning) vs fixed home with temporary moves?
2. **"Any" bike** — auto-assign at booking (leaning) vs leave null for admin?
3. **Disrupted booking awaiting approval** — hold slot (leaning) vs release?

**Deferred but acknowledged (not MVP — recorded so they aren't forgotten):**
- **True reschedule** → MVP is **cancel + rebook** (a real reschedule is an atomic cancel+rebook that re-runs the full availability/bike/location check). Booking flow should at least say "full" gracefully so phase-2 **waitlists** slot in.
- **Late-cancellation charging** → MVP **records** the cancellation (with `cancelled_by` / reason); whether a late cancel auto-creates a ledger charge is deferred — but the student-facing cancel screen should communicate the school's policy.
- **GDPR data export / delete** (student can request their data; sensitive notes are stored) and **basic accessibility** (public + minors) — not design-blocking, but build with them in mind.
- **Audit trail** (who changed what — money, notes, incidents, cancellations) — design schema with room for it; not an MVP screen.

---

## 10. Screens to design (for Claude Design)

A starting screen list, grouped by role. Each is a candidate screen/flow.

**Auth & onboarding**
- Login / signup (role-aware; student signup captures phone number)
- School selection / tenant context (if a user could belong to one school)
- Student profile setup (licence details, transmission preference, category)
- **Pending-approval state** (student home when school requires approval — "awaiting approval", can browse but not book)

**Student app**
- Home / dashboard (upcoming bookings, progress snapshot, CBT/theory status)
- Browse & book — filter by course type, date, location; choose specific bike or "any"
- Booking confirmation + booking detail
- My bookings (upcoming / past) with cancel / reschedule
- Progress view (competencies completed per course, instructor notes)
- Licence & documents (provisional, CBT cert + expiry + variant, theory pass, external test dates)

**Instructor app**
- Schedule (day / week)
- Session detail (student list, bikes assigned, location)
- Availability editor (recurring + one-off, time off)
- Attendance + progress capture (per student, competency checklist + notes)
- **Minimal payment panel** (per student on session/detail view: amount outstanding + record a payment with method) — shown only if the school's "instructors can record payments" toggle is on; not the full ledger

**Admin / management (web-first)**
- Master calendar (all instructors / bikes / locations, filterable) — surfaces **non-blocking travel-time warnings** when an instructor's consecutive sessions span sites with unrealistic gaps
- Bike fleet list + bike detail (status, category, transmission, home/current location, GPS if present)
- Mark bike unavailable (date range + reason)
- Disruption resolution screen (bike-down event → affected bookings → swap / cancel-with-approval)
- End-of-day logistics summary (bikes to move, grouped by destination)
- Instructor management + availability overview
- Locations management — including the **travel-time matrix** (approx minutes between each pair of sites) + per-school travel buffer
- Course type configuration (duration, ratio, required bike category, prerequisites, cancellation policy)
- **Pending sign-ups queue** (students awaiting approval — details + phone, approve/reject) + onboarding-mode setting (open vs approval-required)
- Reports placeholder (phase 2)

**Design notes**
- Admin is **web-first** (dense tables, calendars); student/instructor are **mobile-first**.
- The booking flow is the highest-value flow to get right — show availability honestly (bike-aware capacity, not raw capacity).
- Calendar/scheduling views are the most complex UI — worth dedicated attention.
- **Design the empty / zero states, not just the happy path** — a brand-new school has no bikes/instructors/bookings, and a student search may find nothing available. These should feel intentional ("no slots match — try another date"), not broken.
- **These mock-ups double as a public "preview" landing page** (see Demo / preview) — so the headline flows (booking, master calendar, student detail) should be presentable enough to show prospective schools, not just engineering-functional.

---

## 10b. NEW screens — not yet sent to Claude Design

> Everything below is the **delta** added after the first design handoff. Send just this section to Claude Design as an addition to the existing set.

**Manager — Student detail / overview screen (web-first, manager-only)** — the big new one. A single view of one student that aggregates:
- Where they are in training (progress against competencies, per course type)
- Lessons completed (count of completed bookings)
- **Test history** — practical/Mod attempts with pass/fail and attempt number (region-specific test names); CBT completion status
- **Financial summary** — total charged, total paid, **balance ("owes £50")**, with a payment history list (amount, method, date)
- **Incidents** — any damage events involving this student
- **Safety/accommodation flags** (prominent) + **progress notes** (staff-only)

**Manager — Students list** — searchable/filterable roster, each row showing key at-a-glance status (stage, balance owed, flags) linking into the detail screen above.

**Ledger / payments**
- Record a payment screen/modal (amount, method: cash / bank transfer / card-in-person / other, date)
- Add/adjust a charge (with the auto-on-booking default)
- Balance + history display (reused inside the student detail screen)

**Student notes & flags**
- Add/edit a safety/accommodation flag (structured, factual-phrasing nudge)
- Add/edit a progress note
- Both surfaced to instructors on the session detail / student context, **never to the student**

**Incidents**
- Log an incident (bike, student riding, notes; option to trigger bike unavailability)

**Instructor pay (owed-tracking, NOT payroll)**
- **Manager "what do we owe instructors" screen** — per instructor: earned, paid, outstanding balance. For freelance-heavy schools this is a **frequently-used view** (e.g. end-of-week payout check), not a buried admin panel — design it as a primary management screen.
- Record an instructor earning (manual in MVP; for percentage instructors, tied to a session + its student charges)
- Record an instructor payment (what the school paid out)
- Instructor pay-model config (per instructor: pay basis — percentage / per-day / per-hour / per-student / salary — + rate, optionally per course type). Lives in instructor management.

**Instructor-facing additions**
- Safety flags surfaced prominently on the session detail screen / per-student context, so the next instructor sees "requires low-seat bike" etc. before the lesson.
- (Optional, later) an instructor's own view of what they're owed.

**Notifications & communication**
- In-app **notification centre / bell** (unread events: confirmations, reminders, disruption alerts) — all roles.
- **Notification preferences** screen (per channel + category; separate reminders from urgent issues). MVP defaults can be simple, but design the surface.
- Phone number field on profiles with **click-to-call / click-to-text** affordance (staff-visible only).
- *(Deferred — design later)* booking-scoped messaging, then full chat. Not in the current batch; noted so it isn't designed as student↔student.

**Notes for Claude Design on these**
- The student detail screen is **manager-only and web-first** — dense, multi-panel.
- Money UI is **bookkeeping, not checkout** — no card entry; it's "record what was handed over."
- Notes/flags are **staff-only**; never design a student-facing view of them.

---

## 10c. AMENDMENT — region-specific course structure (NI vs GB)

> **Paste THIS section to Claude Design** to amend any screens that show course types, CBT, or tests. This corrects an earlier GB-only assumption. Initial target is **Northern Ireland**; GB comes later.

**What changed and why:** NI's licensing path is **not** the GB "Mod 1 / Mod 2" structure. NI = provisional → **CBT** → **theory test** → **practical test**. And CBT in NI is **not a single course** — it's run on **different bike sizes by category/age** (the "125 CBT" vs "650 CBT" distinction): roughly A1 (17–19) → 125cc, A2 (19+) → ~500/650cc, A (24) → 600cc. So CBT must be shown as **variants tied to a bike category**, not one fixed item.

**Screens to amend:**
- **Browse & book / course-type filter** — course types are region-specific. For NI, the choices are **CBT variants (e.g. CBT 125, CBT 500/650) + practical training**, not "CBT / Mod 1 / Mod 2". Don't hardcode Mod 1/Mod 2 as the universal set.
- **Course-type configuration (admin)** — must let a school define **region-specific pathway steps** and **CBT-by-bike-category variants**, each linking to a required bike category. (GB schools would configure CBT / Mod 1 / Mod 2 instead.)
- **Licence & documents (student)** — record **which CBT variant / bike category** and region alongside cert + expiry; "theory pass"; and **external test dates** (region-specific names) rather than "DVSA test dates".
- **Student detail — test history (manager)** — label tests by region (NI: practical; GB: Mod 1 / Mod 2). CBT shows as completion status, not pass/fail.
- **Anywhere "Mod 1 / Mod 2" appears literally** — make it driven by the school's region/config, not fixed copy.

**Don't need to change:** the licence categories themselves (AM / A1 / A2 / A) are shared across regions — only the **test/course naming and CBT bike-size variants** differ. Booking flow, calendar, fleet, ledger, notifications screens are unaffected except where they display course-type/test names.

---

## 11. Suggested workflow

1. **This plan** → Claude Design: generate the screen set in section 10, iterate on the booking flow and master calendar first.
2. **Plan + designs** → Claude Code: scaffold Supabase (schema + RLS), then the booking transaction (section 4), then build screens against it.
3. Build order: data model & RLS → auth & roles → fleet/locations/course-type config → availability → booking engine → progress capture → disruption handling → logistics summary.
