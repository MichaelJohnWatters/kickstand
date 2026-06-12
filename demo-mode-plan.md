# Demo-mode + marketing wrapper — implementation plan

**Goal:** ship a static "try it" demo that schools can play with end-to-end,
embedded inside a hand-written marketing page on the company website.
No backend required to host. Always current with the real app.

**Status: ready to build.**

---

## Locked decisions

1. **One source of truth for UI.** The demo IS the real Flutter app, built
   with a flag that swaps the API client for an in-memory mock. We
   don't fork screens, don't maintain a parallel JSX prototype.
2. **All three role shells.** The role picker is the demo's `/welcome` —
   three tiles: Owner / Instructor / Student. Each lands directly in the
   matching shell with a seeded identity (`user_owen`, `user_instr`,
   `user_stu`). No login form, no Firebase round-trip.
3. **Reads → seeded.** Writes → accepted, kept in memory until refresh.
   Visitors see their changes apply, refresh wipes them, no DB or backend
   anywhere.
4. **Marketing wrapper is hand-written HTML/CSS**, separate from the
   Flutter build. Loaded via plain `<iframe loading="lazy" src="/demo/">`
   so the marketing page stays fast and the demo only loads when
   scrolled into view.
5. **Retire `Kickstand Preview.html` + `design_handoff_kickstand/`.**
   They've done their job (design → real implementation). Tag as
   historical, stop touching them.
6. **One build flag everywhere.** `const bool kDemoMode = bool.fromEnvironment('KS_DEMO_MODE')`.
   Production builds default to false; the marketing build sets it to
   true. No runtime switches, no env vars, no per-screen forks beyond
   the provider seam.

---

## What demo mode swaps

| Surface | Production | Demo |
|---|---|---|
| `apiClientProvider` | Real Dio-backed `ApiClient` | `MockApiClient` (in-memory) |
| `authControllerProvider` | Firebase Auth listener | Picks seeded `Identity` based on role picker |
| `/welcome` | Real welcome screen → login/signup | 3-tile role picker |
| Top of every shell | (nothing) | Thin ribbon: "Demo mode — changes won't be saved · Refresh to reset" |
| `firebase_auth` calls | Real | All no-op (`signOut`, etc.) |
| Receipt uploads | multipart POST | Accept, show in-memory thumb, surface "Demo mode — receipt not stored" toast |

Everything else — every screen, every widget, every route — works
unchanged. The demo build literally compiles the same Dart code as
production.

---

## Three role tabs — what each shows

**Owner (Owen)** — full admin sidebar, all screens we've built:
- Overview
- Master calendar
- Students + student detail
- Sign-ups (Rowan pending)
- Bike fleet with the search + filter chips, MOT/tax/mileage pills, gov.uk links
- Bike detail page with the 8 seeded maintenance entries + receipt thumbs
- Disruptions (the YBR125 case)
- Logistics (tomorrow's moves)
- Instructors + instructor pay
- Reimbursements (7 seeded expenses across categories + statuses)
- Locations with Maps links + banner images
- Course types
- Settings

**Instructor (Dave)** — bottom tab nav:
- Schedule with real seeded sessions
- Availability with weekly slots + time-off
- Expenses with 5 seeded rows + new-submission flow
- Profile

**Student (Alex)** — bottom tab nav:
- Home with progress + outstanding £30 + disruption banner
- Book (browse + 4-step booking flow → confirmation)
- Bookings with past + future
- Progress with competency grid
- Licence with seeded photos / details

---

## File layout (new)

```
app/
  lib/
    api/
      mock_api_client.dart       ← in-memory ApiClient. Same interface, no
                                   network. ~300 lines.
      _demo_seed.dart            ← Dart constants — bikes, expenses, sessions,
                                   etc. Generated from the Go seeder so it
                                   stays in sync. ~600 lines.
    screens/
      role_picker_screen.dart    ← 3-tile demo landing. ~120 lines.
    state/
      demo_mode.dart             ← const kDemoMode + helpers. ~30 lines.
      providers.dart             ← apiClientProvider, authControllerProvider —
                                   swap based on kDemoMode. ~10 lines diff.
    widgets/
      demo_mode_banner.dart      ← Top ribbon. Slot into the three shells.

marketing/
  index.html                     ← hand-written hero/features/iframe/pricing.
  styles.css                     ← marketing CSS, separate from Flutter.
  assets/                        ← any marketing imagery.

Makefile                         ← new target: `make web-demo`.
```

---

## Build commands

```
make web-demo        # produces dist/marketing/{index.html, styles.css, …}
                     # and  dist/marketing/demo/   (Flutter web bundle)
                     # — drag dist/marketing/ onto any static host.
```

Pipeline:
1. `flutter build web --release --dart-define=KS_DEMO_MODE=true --base-href=/demo/`
2. Copy `app/build/web/*` → `dist/marketing/demo/`
3. Copy `marketing/*` → `dist/marketing/`

Single rsync to the host, done.

---

## Implementation chunks

1. **MockApiClient + seed constants + build flag.** Get one screen
   (Owner overview) loading entirely from in-memory data with no Dio
   calls. Prove the architecture before fanning out.
2. **Role picker + demo banner.** Replace `/welcome` and add the ribbon.
   All three shells should now be reachable with one click from the
   picker.
3. **Fill in the seed data** for screens that aren't yet covered (push
   to >95% of writes/reads working without falling back to a "Demo mode
   — not implemented" toast).
4. **Marketing HTML + Makefile.** Hand-write the wrapper, wire `make
   web-demo`, smoke-test in a clean browser.
5. **Polish + retire the JSX prototype.** Tag `design_handoff_kickstand/`
   as historical, update STATUS.md to point at the new demo flow.

---

## Out of scope (for v1)

- A real shareable demo URL where two visitors share state. The current
  plan is per-tab in-memory; closing the tab resets.
- Signed receipt URLs (writes don't persist, so receipts don't either).
- Analytics inside the demo. The marketing page can have its own
  Plausible/PostHog snippet for conversion tracking.
- Multi-school demo (one tenant, "Lagan Valley Rider Training"). If we
  ever want school A vs school B side-by-side we can add a school
  picker to the role tile, but not now.

---

## Risks + mitigations

- **Drift between MockApiClient and the real one.** Mitigation: both
  implement the same Dart class (`ApiClient`); add a Dart `abstract
  class` interface that both extend so the compiler enforces parity.
- **Flutter bundle too heavy for marketing site.** Current build is
  ~1.2 MB compressed. The iframe + `loading="lazy"` means it only
  loads when the visitor scrolls to the demo section. Marketing chrome
  itself stays under 50 KB.
- **Demo-mode visible bug somehow ships to production.** Mitigation:
  `kDemoMode` is `bool.fromEnvironment`, defaults to `false`. The
  production build path doesn't pass the flag. CI can add a grep guard
  that fails if `KS_DEMO_MODE=true` shows up in a non-marketing build.
