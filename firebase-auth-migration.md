# Firebase Auth migration — implementation plan

**Status: Phases 0–5 + 1b + 1-full landed 2026-06-08.** Phase 6 (cloud
deploy + GCS receipts) is the only item left. The all-emulator test
migration is done: every httpapi test mints real Firebase ID tokens
via the Auth Emulator and the middleware no longer has a legacy
session-token branch. `internal/auth/` shrank to just `Identity` +
error sentinels + the Firebase verifier. The bcrypt module, the
`Login`/`Authenticate`/`Logout` API, the `/auth/signup` route and the
legacy `signup.Signup` are all gone. The `user_sessions` table and
the `password_hash` column are vestigial (NOT NULL on the column, so
we write empty string until a follow-up migration drops it).

This is the canonical build sheet. The exploratory "should-we" version of
this doc has been collapsed into the locked decisions below; the rest is
ordered phases with deliverables.

---

## Locked decisions

These are settled and not up for re-debate. Their rationale is captured
inline so a future maintainer can see why each call was made.

1. **Provider: Firebase Auth (free Spark tier).** Stays free up to 50 000
   MAU. Lagan Valley has ~10 demo users. If a school ever crosses the
   limit, the Blaze tier is ~$275/mo for managed auth — trivial cost at
   that scale, and we can upgrade with zero code change.
2. **Single source of truth for `role` and `school_id`: our DB.** No
   Firebase custom claims for v1. Role/status changes apply immediately
   on next request because every request does a `firebase_uid` lookup;
   custom claims would require a token refresh round-trip (~1h delay).
   We can add claims later if profiling ever shows the lookup matters.
3. **Local dev: Firebase emulator from day one.** Already scaffolded:
   `firebase.json`, `.firebaserc`, `storage.rules` at repo root,
   `make emulator` starts Auth + Storage + UI. The backend honours
   `FIREBASE_AUTH_EMULATOR_HOST` automatically when set; the Flutter
   client calls `useAuthEmulator('localhost', 9099)` in debug builds.
   Prerequisite for first-time emulator run: bump Node ≥20.
4. **Multi-tenancy: stays in our schema.** Firebase has a tenancy
   concept on Identity Platform; we ignore it. Our `school_id` boundary
   in `tenant.Scope` already works and predates this migration.
5. **Existing-user migration: re-seed.** We have no real users yet, so
   `make seed` against the emulator creates everything. No batch-import
   code, no dual-write window. (If we delay until after launch, this
   plan would gain a `Phase A` for `auth.ImportUsers` against bcrypt
   hashes — but not today.)
6. **Receipt object store: paired but deferred to deploy.** The
   `internal/filestore.Local` implementation keeps working through the
   migration (receipts on disk under `./uploads/`). When we cut to
   cloud deploy we'll add `filestore.GCS` — schema unchanged, single
   file added. See Phase 6.
7. **Phone auth: deferred indefinitely.** Email is enough for MVP; add
   a customer pushes for it.
8. **Project names.** `kickstand-dev` (emulator + future hosted dev),
   `kickstand-prod` (production). Service-account credential JSON for
   the prod project arrives at deploy time — not blocking dev work.
9. **Public endpoints stay public.** `GET /schools` and `GET /health`
   stay open by design (catalog + infra probes). After cutover, the
   only login-tier surface is `POST /auth/signup` — and even that is
   authed (Flutter calls Firebase create-user *first*, then POSTs the
   profile body with the resulting JWT).

---

## Why this is small

The whole codebase is wired around an `Identity{UserID, SchoolID, Role,
…}` contract that handlers read via `identityFromContext(ctx)`. We
preserve that contract: only the *production* of `Identity` changes (one
file: `internal/httpapi/middleware.go`). Every booking / disruption /
expense / calendar handler is untouched.

```
Today:  Bearer <opaque>  → lookup user_sessions → Identity
After:  Bearer <JWT>     → VerifyIDToken + lookup by firebase_uid → Identity
```

Net code delta:
- ~150 LOC removed (`Login`, `Logout`, `Authenticate`, session-table
  queries, bcrypt usage, `TokenStorage`).
- ~120 LOC added (Verifier, middleware swap, `firebase_options.dart`,
  `AuthController` rewrite).
- 1 schema migration (`0005_firebase_uid`).
- Every handler downstream: zero changes.

---

## Phase 0 — Foundations

**Goal:** all the moving parts ready in their inert state. After this
phase the repo still runs the old auth; nothing is broken.

**Deliverables:**

- [ ] `migrations/0005_firebase_uid.up.sql` — `ALTER TABLE users ADD
      COLUMN firebase_uid TEXT;` + partial unique index. Nullable for
      safe co-existence with old data during cutover.
- [ ] `go.mod` — add `firebase.google.com/go/v4` (Go Admin SDK).
- [ ] `app/pubspec.yaml` — add `firebase_core` and `firebase_auth`
      Dart packages.
- [ ] `app/lib/firebase_options.dart` — hand-rolled placeholder pointing
      at the `kickstand-dev` project. Sufficient for the emulator; we
      swap to `flutterfire configure`-generated when we have a real
      project.
- [ ] `app/lib/main.dart` — wrap `runApp` in `Firebase.initializeApp` +
      `useAuthEmulator` for debug builds. No-ops at runtime until
      something *calls* `FirebaseAuth.instance`.
- [ ] `cmd/server/main.go` — construct the Firebase `*auth.Client`,
      pass it to the `Server` (but don't use it yet — the existing
      middleware still wins).
- [ ] `flutter analyze` and `go test ./...` both pass.

---

## Phase 1 — Backend swap

**Goal:** Go server verifies Firebase tokens. The old `/auth/login`
endpoint still works in this phase (it issues a Firebase custom token
the client immediately exchanges) **only if needed** — easiest path is
to delete it now since Flutter doesn't ship Phase 3 yet.

**Recommended path:** delete `/auth/login` / `/auth/logout` immediately
and use the Firebase Admin SDK's `CreateCustomToken` from a test
helper to mint JWTs for the existing HTTP test suite.

**Deliverables:**

- [ ] `internal/auth/firebase.go` — new `Verifier` type wrapping
      `auth.Client`. Methods: `VerifyAndLoad(ctx, token) (*Identity, error)`
      and `LoadByFirebaseUID(ctx, uid)`.
- [ ] `internal/httpapi/middleware.go` — `authMiddleware` calls
      `Verifier.VerifyAndLoad`. Same `Identity` attached to context.
- [ ] `internal/httpapi/server.go` — `Server` struct gains
      `Auth *auth.Verifier`. Constructor accepts it.
- [ ] `internal/httpapi/auth_handlers.go` — delete `handleLogin` and
      `handleLogout` (Flutter calls Firebase directly post-Phase 3).
      `handleSignup` becomes authed and reads UID from the token.
- [ ] `internal/httpapi/server.go` — drop `POST /auth/login` and
      `POST /auth/logout` routes.
- [ ] `internal/httpapi/testhelpers_test.go` — replace the old
      "obtain bearer token via login" helper with one that calls the
      emulator's `CreateCustomToken` then exchanges it for an ID
      token. Existing per-test helpers (`asOwen`, `asAlex`, …) keep
      the same signatures.
- [ ] CI / `go test ./...` runs against the Firebase emulator. The
      emulator must be running on `localhost:9099` with
      `FIREBASE_AUTH_EMULATOR_HOST` exported.
- [ ] All ~200 existing httpapi tests pass against the new middleware.

---

## Phase 2 — Seed via Admin SDK

**Goal:** `make seed` produces a working demo tenant against the
emulator: Firebase users + matching local profile rows.

**Deliverables:**

- [ ] `cmd/seed/main.go` — for each demo user, call
      `firebaseAuth.CreateUser` with a pinned `UID` (re-use our local
      `user_id` string — they're both opaque text, makes re-seeding
      idempotent). Insert the local row with that same `firebase_uid`.
- [ ] Seed binary respects `FIREBASE_AUTH_EMULATOR_HOST` so it works
      against the emulator with zero credentials.
- [ ] `make seed` smoke: emulator UI shows ~12 users; the Go server
      can list `/students` for Owen against the new DB.

---

## Phase 3 — Flutter swap (login + AuthController)

**Goal:** the Flutter app authenticates against Firebase. Login screen
unchanged visually; the implementation behind it is the SDK.

**Deliverables:**

- [ ] `app/lib/state/auth.dart` — `AuthController` rewrites to wrap
      `FirebaseAuth.instance.authStateChanges()`. `_restore` goes away
      (the SDK rehydrates on app start). Sign-out is `signOut()`.
- [ ] `app/lib/state/providers.dart` — `apiClientProvider`'s
      `tokenSupplier` becomes `await FirebaseAuth.instance.currentUser
      ?.getIdToken()`.
- [ ] `app/lib/api/client.dart` — drop `login(email, password)` and
      `logout()`; the API client only carries the Bearer token now.
- [ ] `app/lib/state/token_storage.dart` — delete. SDK manages its own
      persistence.
- [ ] `app/lib/screens/login_screen.dart` — same UI, calls
      `FirebaseAuth.instance.signInWithEmailAndPassword`. Maps Firebase
      errors (`user-not-found`, `wrong-password`, …) to friendly copy.
- [ ] Restart-survival manually tested: log in, kill the app, reopen,
      should be at the role landing page without prompting.

---

## Phase 4 — Signup screen (the work we deferred) ✅

**Goal:** new students can create their own account.

**Deliverables:**

- [x] `app/lib/screens/signup_screen.dart` — fields: name, email,
      password, phone, category, transmission. School picker reads
      `GET /schools`.
- [x] Submit flow:
      1. `FirebaseAuth.createUserWithEmailAndPassword`
      2. `POST /auth/firebase-signup` with the JWT in the Authorization
         header — server verifies UID via Admin SDK and writes the
         local users + student_profiles row, gating on the school's
         onboarding_mode.
      3. AuthController's `authStateChanges` listener fires; router
         redirect lands the user at `/student` (open) or pending
         screen (approval).
- [x] `app/lib/screens/welcome_screen.dart` — "Create account" button
      live, routes to `/signup`.
- [x] `internal/httpapi/signup_handlers.go` — `handleFirebaseSignup`
      verifies the JWT manually (regular middleware can't help — the
      profile row doesn't exist yet) and calls
      `signup.SignupWithFirebase`.
- [x] Profile-write failure rolls back the Firebase user so the email
      stays available for retry.

---

## Phase 5 — Email verification + password reset ✅

**Goal:** the two features that motivated this migration.

**Deliverables:**

- [x] After successful signup, call `user.sendEmailVerification()`
      (best-effort, non-blocking).
- [x] `app/lib/widgets/email_verification_banner.dart` — top-of-shell
      banner for unverified users, slotted into Student / Instructor /
      Admin shells. Resend (60s cooldown), "I've verified" (calls
      `user.reload()`), session-only dismiss.
- [x] Login screen "Forgot password?" link → dialog → calls
      `AuthController.sendPasswordReset` →
      `FirebaseAuth.sendPasswordResetEmail`. Existence of the email
      is not leaked.
- [ ] Confirm the emulator shows the verification + reset emails in
      its UI (manual verification step — emulator records the
      template at `localhost:9099` even though it doesn't deliver).

---

## Phase 6 — Cloud deploy + receipt storage swap

**Goal:** real production deploy. Receipt storage flips from local
filesystem to Google Cloud Storage as part of the same deploy.

**Deliverables:**

- [ ] Stand up `kickstand-prod` Firebase project + service-account JSON.
- [ ] `internal/filestore/gcs.go` — new `Store` implementation.
- [ ] `cmd/server/main.go` — branch on env: local filesystem in dev,
      GCS in prod.
- [ ] Cloud Run / Render config: env vars `GOOGLE_APPLICATION_CREDENTIALS`
      + `FIREBASE_PROJECT_ID` + the receipt bucket name.

Out of scope for the initial migration. Tracked here so it doesn't
disappear.

---

## Test plan

For each phase before merging:

- [ ] Owen logs in (Firebase), hits `/disruptions`, gets owner-only
      data.
- [ ] Owen calls `signOut()` client-side. A request 5 minutes later
      with the cached token still verifies (JWTs are stateless); after
      ~1h it 401s.
- [ ] Disabled student: token verifies; middleware rejects with 403
      `account_disabled`.
- [ ] Token forged with the wrong issuer / audience: 401
      `session_invalid`.
- [ ] New student signs up in Open-mode school → lands in `/student`.
- [ ] New student signs up in Approval-mode school → lands on pending
      screen; Owen sees them in `/admin/signups`.
- [ ] Forgot password: emulator UI shows the reset link; clicking it
      sets a new password; logging in with it succeeds.
- [ ] All ~200 existing httpapi tests pass against the emulator.

---

## Rollback

Each phase is a single PR with a focused commit; rollback is `git
revert` plus re-running the down migration if Phase 0 has landed.

The Firebase emulator data is ephemeral — restarting it wipes users —
so dev rollback is `make seed` against the fresh state.

There's no production rollback story yet because there's no production
yet.

---

## Risks

- **Emulator not running during dev.** Symptom: every request 401s on
  signup. Mitigation: `make run` aborts with a clear message if it
  can't reach `localhost:9099` and `FIREBASE_AUTH_EMULATOR_HOST` is
  unset.
- **Token verification CPU cost.** ~50µs per request (key cache hit).
  Negligible.
- **`firebase-tools` Node-version drift.** CLI v15 needs Node ≥20.
  Captured in the README.

---

## TL;DR

- We have the design, the emulator config, and a clear contract.
- Six phases; Phase 0 is plumbing that breaks nothing, Phase 1 is the
  one substantive code change, Phases 2–5 are mechanical.
- ~1.5 days of focused work for "signup works, password reset works,
  emulator-based dev loop is green."
- Production deploy + GCS receipts is Phase 6 — separate concern.
