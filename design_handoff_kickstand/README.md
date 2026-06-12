# Handoff: Kickstand — Rider Training Management Platform

> **ARCHIVED 2026-06-12.** This bundle was the original design prototype
> handed off to engineering. Its job is done — the real Flutter app under
> `app/` is now the source of truth for UI, and the runnable demo lives
> at `dist/marketing/` (see `demo-mode-plan.md`). Files here are kept
> for historical reference (design tokens, copy, interaction notes) but
> are no longer edited. Same applies to `Kickstand Preview.html` at the
> repo root.

## Overview
Kickstand is a multi-tenant SaaS for UK motorcycle training schools. This bundle is the **design prototype** for the MVP across three clients:
- **Student** (mobile-first) — browse & book training, manage bookings, track progress & licence/test documents.
- **Instructor** (mobile-first) — day/week schedule, session detail + attendance, competency sign-off, availability, in-field payment recording.
- **Admin / Owner** (web-first) — master calendar, students, fleet, disruptions, logistics, instructor pay, course config, sign-up approvals.

Plus an **auth & onboarding** flow (role-aware login, signup with phone, school selection, licence profile, approval-pending state).

The demo tenant is **Lagan Valley Rider Training** (Northern Ireland — Belfast / Lisburn / Newry). The build plan it implements is the source of truth for behaviour; this README maps that plan to the screens.

## About the Design Files
**The files in this bundle are design references created in HTML/React (via in-browser Babel).** They are prototypes showing intended look and behaviour — **not** production code to ship. The task is to **recreate these designs in the real target stack** described in the plan: **Flutter (iOS/Android + Flutter Web)** against **Supabase (Postgres + Auth + RLS + Realtime)**. Use the codebase's eventual established patterns; treat the HTML as the visual + interaction spec, not as code to port line-for-line.

Mock data, in-memory state, and the role launcher exist only to make the prototype explorable — they are not part of the product (the real app has auth + a backend; a logged-in user is one role in one tenant).

## Fidelity
**High-fidelity.** Final colours, typography, spacing, radii, shadows, copy, and interactions are all intended as drawn. Recreate the UI faithfully using Flutter equivalents of the tokens below. The one deliberate placeholder: location "site map" thumbnails use a striped placeholder (no real map integration in MVP).

---

## Design tokens
All defined as CSS custom properties in `app/tokens.css`. Colours are authored in **oklch** (convert to hex/Flutter `Color` as needed; approximate hex given for convenience).

### Type
- **UI / display:** `Plus Jakarta Sans` (weights 400/500/600/700/800). Geometric, friendly.
- **Mono (plates, refs, codes):** `Space Mono`.
- Alternate faces wired as tweakable options: `Manrope`, `Space Grotesk`.
- Headings use tight tracking: `letter-spacing: -0.02em to -0.04em`, weight 800.

### Colour — light theme (cool neutrals + indigo)
| Token | oklch | ~hex | Use |
|---|---|---|---|
| `--bg` | 0.969 0.006 275 | #f3f4f7 | app background |
| `--surface` | #ffffff | #ffffff | cards |
| `--surface-2` | 0.985 0.005 275 | #fafbfc | insets |
| `--surface-3` | 0.965 0.007 275 | #eef0f4 | track/fills |
| `--border` | 0.915 0.008 275 | #e4e6ec | hairlines |
| `--border-2` | 0.86 0.012 275 | #d2d5df | strong borders |
| `--ink` | 0.27 0.035 277 | #2c2b46 | primary text |
| `--ink-2` | 0.49 0.028 277 | #5d5c77 | secondary |
| `--ink-3` | 0.635 0.022 277 | #8786a0 | tertiary |
| `--ink-4` | 0.75 0.018 277 | #aaa9bd | muted/icons |
| `--primary` | 0.55 0.20 277 | #6366f1 | brand / CTAs |
| `--primary-deep` | 0.40 0.16 277 | #4338ca | headers/gradients |
| `--primary-tint` | 0.955 0.030 277 | #ececfb | soft bg |
| `--success` | 0.58 0.13 160 | #1f9d6b | ready/paid/pass |
| `--warning` | 0.70 0.135 70 | #c98a1e | tight/pending |
| `--danger` | 0.575 0.185 25 | #d64242 | down/owed/fail |
| each semantic also has a `--*-tint` soft background |

Accent hue is tweakable (`--primary-h`: indigo 277 default; violet/blue/teal/green/coral options). A **dark theme** is defined under `[data-theme="dark"]`.

### Radius / shadow / motion
- Radii: `--r-xs 8 · --r-sm 11 · --r 14 · --r-lg 20 · --r-xl 28 · --r-pill 999` (px). Tweakable "corners" scale (rounded/soft/sharp).
- Shadows: `--sh-1` (subtle card), `--sh-2` (hover/raised), `--sh-3` (modals), `--sh-primary` (indigo CTA glow).
- Animations (in tokens.css): `ks-fade-up` (screen enter .34s), `ks-pop` (success/toast), `ks-sheet-up` (bottom sheet), `ks-scale-in` (modal). Easing `cubic-bezier(.22,.9,.3,1)`.
- Mobile hit targets ≥ 44px; bottom-sheet grabber; iOS safe-area padding on tab bars.

---

## Architecture of the prototype (file map)
Load order matters (later files depend on earlier globals). All JSX is transpiled in-browser; components are shared via `Object.assign(window, …)`.

| File | Contents |
|---|---|
| `app/tokens.css` | design tokens, base styles, keyframes, theme + density data-attrs |
| `app/icons.jsx` | `Icon` component — curated Lucide-style stroke set + custom `moto`/`qr` glyphs |
| `app/ui.jsx` | shared kit: `Btn, Avatar, Card, Badge, BikeStatus, Seg, ProgressBar, ProgressRing, Sheet, Modal, TabBar, SectionLabel, Toast, BikeGlyph, QRCode, ShareSheet, KField/KInput/KArea/KSelect` |
| `app/data.jsx` | core mock data: `SCHOOL, PATHWAY, LOCATIONS, COURSE_TYPES, BIKES, INSTRUCTORS, ME, SESSIONS, MY_BOOKINGS, COMPETENCIES, compsFor, MY_PROGRESS, DISRUPTION, LOGISTICS, PENDING` + lookups |
| `app/data2.jsx` | manager data: `SREC` (per-student records), `balanceOf`, ledger `PAY_METHODS`, `INSTRUCTOR_PAY`, `NOTIFS`, `NOTIF_CATEGORIES/PREFS`, `TRAVEL` matrix, `TEST_LABEL` |
| `app/notifications.jsx` | `NotifCenter`, `NotifPrefs`, `NotifBell`, `Switch` (shared) |
| `app/auth.jsx` | `AuthApp` — welcome / login / signup(+phone) / school select / profile / done(approval-aware) |
| `app/student-book.jsx` | `StudentBook` booking flow + `suitableBikes`, `honestCapacity`, `Empty` |
| `app/student.jsx` | `StudentApp` — home, my bookings, progress, licence & docs, confirmation, cancel/reschedule, pending state |
| `app/instructor.jsx` | `InstructorApp` — schedule (day/week), session detail, attendance, competency capture, availability, profile, in-field payments |
| `app/admin-fleet.jsx` | `FleetScreen` (+ add/unavailable), `DisruptionScreen`, `PageHead`, table styles |
| `app/admin-students.jsx` | `StudentsScreen` (list + detail: progress, tests, ledger, incidents, notes/flags) + record-payment/charge/flag/note/incident modals |
| `app/admin-signups.jsx` | `SignupsScreen` — onboarding mode toggle + pending queue, `EmptyState` |
| `app/admin-pay.jsx` | `InstructorPayScreen` — owed-tracking, earning/payment, pay-model config |
| `app/admin.jsx` | `AdminApp` shell (sidebar nav), Overview, MasterCalendar, Logistics, Instructors, Locations(+travel matrix), Courses(+config) |
| `app/shell.jsx` | role launcher, top-bar role switcher, auto-fit staging, Tweaks panel wiring |
| `frames/` | device/chrome scaffolds (iOS bezel, browser window) + tweaks panel — **prototype-only chrome, not part of the product** |

> The device frames, role launcher, and Tweaks panel are presentation scaffolding for the prototype. In the real app, the student/instructor apps are Flutter screens and admin is Flutter Web — no bezel, no launcher, no role switcher.

---

## Screens & views

### Auth & onboarding (`auth.jsx`) — mobile
- **Welcome** — indigo full-bleed, logo, headline, "Create account" / "I already have an account".
- **Login** — email + password (show/hide), forgot link; role-aware (routes to the user's role on success).
- **Signup** — name, email, **mobile number** (with staff-only/GDPR note), password. 3-step progress. Note that instructors join by invite.
- **School select** — searchable tenant list, radio-style cards (multi-tenant context).
- **Profile setup** — provisional licence no., **category AM/A1/A2/A** (segmented), transmission (manual/auto), CBT held?, theory passed?
- **Done** — **approval-aware**: if the school's `onboardingMode==='approval'`, shows "Almost there / awaiting approval" (amber) and lands the student in **pending** state; else success → dashboard.

### Student app (`student.jsx`, `student-book.jsx`) — mobile, bottom tab bar (Home / Book / Bookings / Progress)
- **Home** — greeting, **pending-approval banner** when applicable, "Next up" gradient hero (next booking), licence-journey stat tiles (CBT valid, theory), upcoming external test countdown, progress snapshot ring, links to Licence & docs + Invite-a-friend (QR `ShareSheet`).
- **Browse & book** (the marquee flow, 4 steps):
  1. Course type list — region-specific (NI: **CBT 125 / CBT 500-650 / CBT 600 / Practical training / Practical test day**). Locked courses show a non-blocking reason (e.g. CBT 600 "requires 24+"). `non_teaching` test days carry a "Test day" badge.
  2. Slot list — per-site filter; **bike-aware "honest" capacity**: bookable = `min(capacity − booked, suitable free bikes)`; shows "N places left" / "Full" / free-bike count. Empty state "No slots match — try another site or week."
  3. Bike choice — "Any suitable" (auto-assign) or a specific suitable bike; cross-site bikes flagged.
  4. Review — summary + cancellation policy + price; soft advisory on test days ("bring your CBT cert + theory pass"). **Pending students see a disabled "Awaiting approval to book"** instead of Confirm.
  - **Confirmation** screen with success pop.
- **My bookings** — upcoming/past segmented; cards with **Cancel** (sheet, policy-aware, 48h cutoff) and **Reschedule** (sheet listing alternative bike-aware slots → cancel+rebook).
- **Progress** — per course: competency checklist with sign-offs + instructor note.
- **Licence & documents** — provisional licence card, CBT cert + expiry + **variant**, theory pass, **DVA external test** dates (region-named, not "DVSA").

### Instructor app (`instructor.jsx`) — mobile, tab bar (Schedule / Availability / Expenses / Profile)
- **Schedule** — Day/Week toggle; day = today's sessions with roster avatars; week = 7-day rail. Header has notification bell + a **QR "join school" code**.
- **Session detail** — date/time/location; **safety flags surfaced prominently per student** (amber); click-to-call student; attendance (Present/No-show); **Assess** → competency capture (skipped for `non_teaching` test days, which show a "Test day — no assessment" banner). **In-field payment**: when `SCHOOL.instructorsCanRecordPayments` is on and the student owes, an "Outstanding £X · Record payment" row opens a sheet (amount + method, stamps "Recorded by [instructor]"). Record-only — no void/charge editing.
- **Availability** — weekly recurring grid (tap to offer/remove), time-off list.
- **Expenses** — submit out-of-pocket spend (petrol, lunch, parking, tolls, other) with a **required receipt photo**. List view groups by **Pending review / Approved (awaiting payment) / Reimbursed / Rejected** with an "Awaiting reimbursement" hero total. Add flow: snap receipt → category chip → amount + where + optional notes → submit. Detail screen shows the photo and status footnote (paid-on for reimbursed, owner reason for rejected). Pending items can be **edited or withdrawn** by the instructor.
- **Profile** — qualifications, notification preferences, sign out.

### Admin / Owner (`admin.jsx` + `admin-*.jsx`) — web, fixed sidebar
Sidebar: school switcher, nav (Overview, Master calendar, Students, Sign-ups•badge, Bike fleet, Disruptions•badge, Bike logistics, Instructors, Instructor pay, Locations, Course types), user card with bell + settings.
- **Overview** — KPI cards (sessions today, bikes ready, instructors on, week occupancy), "Needs attention" (disruption + logistics), today's sessions.
- **Master calendar** — week timeline, time axis 08–18, sessions as positioned colour-coded blocks, per-site filter, **non-blocking tight-travel warning** banner.
- **Students** — searchable/filterable roster (stage, lessons, balance owed, flags) → **Student detail** (web-first, dense, manager-only): progress rings per course, **DVA test history** (attempts, pass/fail/booked, region-labelled), **financial summary** (charged/paid/derived balance + dated history), incidents, **safety/accommodation flags** (prominent) + **staff-only notes**, click-to-call/text. Modals: record payment, add charge, add flag, add note, log incident (with "take bike offline" option).
- **Sign-ups** — **onboarding-mode toggle** (open vs approval-required) + **pending queue** (applicant details, phone, approve/reject). Empty states for both modes.
- **Bike fleet** — table (model, reg, cat, transmission, home/current location with cross-site flag, status); take-offline modal (reason) / restore; add-bike modal.
- **Disruptions** — bike-down event banner + affected bookings → **swap** (auto-suggested suitable bike) / **cancel-with-approval** (slot held) / pending.
- **Bike logistics** — derived end-of-day view: bikes to move grouped by destination ("Lisburn needs bike A from Belfast"), mark-moved.
- **Instructors** — staff cards + **"instructors can record payments" per-school toggle**; add-instructor modal (name, home site, qualified course types).
- **Instructor pay** (owed-tracking, NOT payroll) — total outstanding header, per-instructor earned/paid/outstanding, record earning (percentage entries reference the session + its charges), record payment, **pay-model config** (percentage / per-day / per-session / per-hour / per-student / salary, optional per-course override). Salaried = not tracked.
- **Reimbursements** — review instructor-submitted expenses, approval-first workflow (owner approves *before* reimbursement). Three KPIs (Pending review · Approved & owed · This month). Tabs filter the table by status; pending rows expose **Approve / Reject** inline with a receipt-thumbnail preview that opens the full photo in a modal. Rejection requires a reason (instructor sees it). Kept **separate from Instructor pay** by design so reimbursements have their own audit trail and don't pollute the earnings ledger.
- **Locations** — site cards + **travel-time matrix** (approx minutes between sites) + per-school setup buffer.
- **Course types** — region banner (NI pathway), per-type cards (duration, ratio, required bike category, prerequisites, cancellation, price); **editor modal** (name, code, icon, accent, duration, price, ratio, required category, prerequisite chips, **"Test day (non-teaching)" toggle**).

### Notifications (`notifications.jsx`) — all roles
Bell with unread dot → **centre** (event feed, mark-all-read) → **preferences** (per category × Email/Push/SMS; SMS marked phase-2; quiet-hours note). Categories separate routine reminders from urgent issues.

---

## Interactions & behaviour
- **Screen transitions**: `ks-fade-up` on each screen mount. Sheets slide up (`ks-sheet-up`); modals scale-in; success uses `ks-pop`.
- **Toasts**: transient confirmation (`Toast` mobile, inline on admin), ~2s.
- **Bike-aware capacity** is the headline behaviour — never show raw capacity; compute `min(capacity−booked, suitable free bikes)`. Same matching ("suitable = right category + transmission + ready + reachable") drives disruption swap suggestions.
- **Warn-don't-block** everywhere: travel-time, CBT-expiry, test-day document reminders are advisories, never hard gates. **No licensing-rules engine** (see plan §4).
- **Pending students**: browse-but-not-book (confirm disabled).
- **Reschedule** = cancel + rebook (re-runs availability). MVP says "full" gracefully (phase-2 waitlist).
- **Hover/active**: cards lift to `--sh-2`; buttons scale .96 on press.

## State management (what the real app needs)
Prototype uses local React state; the real app is Supabase-backed with RLS per `school_id`. Key state/data per the plan's data model:
- Auth/session → role + tenant; `account_status` (active / pending-approval).
- Booking transaction (plan §4) — atomic: instructor available+qualified, bike suitable+free+reachable, student eligible (advisory), capacity & suitable-bike check. Prevents double-booking the last slot/bike.
- Derived values (never stored): student balance (charges − payments), instructor owed (earnings − payments), logistics mismatches, bike-aware capacity, travel-time feasibility.
- Per-school config: `onboardingMode`, `instructorsCanRecordPayments`, cancel cutoff, cross-site notice, travel buffer + matrix, region, course types.
- `recorded_by` on payments is the accountability hook (feeds the deferred audit trail).

## Region model (NI vs GB) — important
Course/test structure is **per-school, region-aware** — do not hardcode GB's Mod 1/Mod 2. NI (the demo): provisional → **CBT (bike-category variants: 125 / 500-650 / 600)** → **theory** → **practical test**. CBT is completion-based (completed / needs return day), external tests are pass/fail/booked with attempt numbers. Licence categories (AM/A1/A2/A) are shared across regions; only test/course naming + CBT variants differ. Test authority label is data-driven (`SCHOOL.body` = "DVA" for NI, "DVSA" for GB). `TEST_LABEL` maps test types to display names.

## Assets
No raster image assets. Icons are inline stroke SVGs (`app/icons.jsx`, Lucide-derived MIT + custom `moto`/`qr`). QR codes generated at runtime via `qrcode-generator` (CDN) → data URLs. Fonts from Google Fonts. Location "site map" is an intentional striped placeholder. Replace icon set with the codebase's icon library; keep the custom motorbike glyph or substitute a brand mark.

## Files in this bundle
- `Kickstand.html` — entry point (load order + CDN pins for React 18.3.1 / Babel / qrcode-generator).
- `app/*.jsx`, `app/tokens.css` — the design source (see file map).
- `frames/*` — prototype-only device/chrome scaffolds.
- `Kickstand Preview.html` — the self-contained, offline single-file build (this is what's hosted as the public sales "preview"; **not** for implementation reference — use the `app/` sources).

To run the multi-file source locally: serve the folder over HTTP (the `<script src>` imports need a server, not `file://`) and open `Kickstand.html`.
