# Firebase Auth migration plan

Status: **drafted, awaiting decision.** Last updated 2026-06-07.

This is the migration plan from our current rolled-own session auth
(`internal/auth/`) to Firebase Auth. Nothing in here has been implemented
yet — the goal is to capture the shape of the work, the trade-offs, and the
decisions we need to make before kickoff.

---

## Why migrate

The current auth in `internal/auth/auth.go` (~240 LOC + tests) handles the
basics well: bcrypt cost-10, opaque 32-byte session tokens, constant-time
login response, server-side revocation, no email enumeration. It's not where
we'd get pwned.

It does **not** cover the operational hardening that real users expect:

1. **No rate limiting** on `/auth/login` — anyone can brute-force.
2. **No password reset** flow — reset token table + email delivery + abuse
   resistance is a non-trivial build.
3. **No email verification** — open-mode schools accept fake emails today.
4. **No account lockout** after N failed attempts.
5. **No 2FA** — matters for owners handling instructor pay.
6. **Long-lived sessions** (30 days) with no rotation — leaked tokens stay
   valid for a month.
7. **Flutter web** stores tokens in `localStorage` (XSS-exposed). Mobile is
   Keychain/Keystore, fine.

Building all of those ourselves is a real chunk of work — each is its own
attack surface that needs to be correct, kept correct, and tested. Firebase
Auth gives us 1–5 turnkey, plus social login and OAuth when we want them.

The trigger for revisiting was the student self-signup screen: rather than
build signup on top of rolled-own auth and then build password-reset on top
of that, do the swap first.

---

## What changes

### Backend (`internal/auth/`, `internal/httpapi/middleware.go`)

| Today | After Firebase |
|---|---|
| `auth.Login(email, password)` validates bcrypt, inserts a row in `user_sessions`, returns a 32-byte hex token. | Gone. Client gets a Firebase ID token directly from the Firebase SDK. |
| `auth.Authenticate(token)` looks up `user_sessions` JOIN `users`, checks `expires_at` / `revoked_at`. | Gone. Replaced with `firebase.App.Auth().VerifyIDToken(ctx, token)` — verifies the JWT signature against Google's rotating keys, returns the Firebase UID + claims. |
| `auth.Logout(token)` UPDATEs `user_sessions.revoked_at`. | Gone. Logout is client-side (`FirebaseAuth.instance.signOut()`); server is stateless. |
| `auth.Identity{UserID, SchoolID, Role}` carried through middleware. | **Same struct, same contract.** `UserID` becomes the Firebase UID. We look up `SchoolID` and `Role` from our own `users` table keyed on UID. |
| `authMiddleware` reads `Bearer <opaque-token>`. | `authMiddleware` reads `Bearer <firebase-id-token>`, verifies, looks up profile, attaches `Identity`. |

Concrete diff size: ~80 LOC removed (`Login`, `LogoutAt`, session table
queries), ~60 LOC added (Firebase SDK init, token verification, profile
lookup), middleware change is ~20 lines. **The whole rest of the codebase
is untouched** — every handler reads `identityFromContext(ctx)` and gets
the same `Identity` struct it does today.

### Schema (migration `0004_firebase_auth.up.sql`)

- `users` table: drop `password_hash` (or keep nullable for rollback). Add
  `firebase_uid TEXT UNIQUE NOT NULL` — the primary join key from the
  Firebase token to our profile data.
- `user_sessions` table: drop. Firebase tokens are stateless JWTs; we don't
  store them.
- `email` stays on `users` (we still need it for the admin signups screen
  and for display), but Firebase becomes the source of truth for
  email-verified status.

### Flutter client (`app/lib/state/auth.dart`, `app/lib/api/client.dart`)

| Today | After Firebase |
|---|---|
| Login screen POSTs `{email, password}` to `/auth/login`, stores opaque token. | Login screen calls `FirebaseAuth.signInWithEmailAndPassword(...)`, then calls `user.getIdToken()` to get the JWT. |
| `TokenStorage` writes the opaque token to `flutter_secure_storage`. | Gone. Firebase SDK manages token storage + refresh in the background (15-minute access tokens, refresh tokens cached on-device). |
| `_tokenSupplier` returns the stored token. | `_tokenSupplier` returns `await FirebaseAuth.instance.currentUser?.getIdToken()`. The SDK auto-refreshes before expiry. |
| `AuthController._restore()` reads stored token, calls `/me`. | `AuthController` subscribes to `FirebaseAuth.authStateChanges()` — instant rehydrate on app start, fires on sign-out. |

### New: signup screen (built on the new auth)

This is the work that was deferred. Signup becomes ~150 lines of Flutter
because Firebase handles password complexity, email validation, and
duplicate-email errors out of the box:

1. User picks school (we ship a list from `GET /schools`).
2. Form: name, email, password, phone, category, transmission.
3. `FirebaseAuth.createUserWithEmailAndPassword(...)` → got UID.
4. POST `/auth/signup` to our backend with `{firebase_uid, school_id, name,
   phone, category, transmission}` → backend creates the `users` +
   `student_profiles` row, gates on `school.onboarding_mode` (open vs
   approval).
5. Open mode → land on `/student`. Approval mode → land on the
   "pending approval" screen.

### Email verification + password reset (free)

- After signup, send verification email via
  `user.sendEmailVerification()` — one line, no backend code.
- Password reset: `FirebaseAuth.sendPasswordResetEmail(email)` — one line,
  Google handles the email + token + reset page.
- Both can be turned on the moment Firebase is wired; no incremental work.

---

## Migration approach for existing users

Two paths, depending on what stage you do this:

### A) Pre-launch (recommended)

We have **no real users yet** — only seeded demo accounts. Easiest path:

1. Stand up the Firebase project (dev + prod).
2. Switch the codebase over.
3. Re-seed the demo accounts via Firebase Admin SDK in the seed binary.
4. Done.

Zero migration code.

### B) Post-launch (if we delay the migration)

Use Firebase's [batch import](https://firebase.google.com/docs/auth/admin/import-users)
to copy users in bulk. We have bcrypt hashes already, and Firebase supports
bcrypt-hashed import — so users keep their existing passwords and don't see
a "please reset" prompt. Two-week rollout window:

1. Dual-write: every signup goes to both stores; every login tries Firebase
   first, falls back to bcrypt, then auto-migrates the user's hash into
   Firebase.
2. After two weeks of dual-write, batch-import the long tail (sleepers).
3. Drop the old code path.

A bit fiddly, but standard.

---

## What we keep, what we lose

### Keep
- `Identity` contract — every handler still reads it from context.
- `tenant.Scope` and the `school_id` guard — the security boundary is
  unchanged.
- Bearer-token authorization model — just a different token type.
- Logout UX — client triggers `signOut()`; the rest is plumbing.

### Lose
- Self-hosted identity. Google becomes the SPOF for sign-in. If Firebase
  Auth is down (very rare; SLO 99.95%), nobody can sign in. Existing tokens
  keep working for up to an hour.
- Local dev simplicity. We add the Firebase emulator
  (`firebase emulators:start --only auth`) to `make run` — works fine but
  is another thing to install.
- The `user_sessions` audit trail. Firebase Auth gives you a sign-in log in
  the console but it's not queryable from our DB.
- The ability to log a user out **everywhere** instantly. With JWTs, an
  attacker with a stolen token has up to 1 hour (the token's remaining
  lifetime) before refresh enforces re-auth. We can revoke the user's
  refresh token immediately via `Admin SDK`, which forces re-login within
  ~1h. Comparable to current 30-day window — strictly better.

### Cost
- **$0/month** at Spark tier up to 49,999 MAU. We have ~10 demo users.
- **$0.0055/MAU** above 50k on the Blaze tier. Lagan Valley would have to
  grow to 50k active monthly users to pay anything — and at that point
  $275/mo for managed auth is trivial.
- SMS for phone-based 2FA is metered separately (~$0.01 per SMS). Defer
  enabling phone 2FA until we want it.

---

## Phased rollout

Suggested order — each phase is independently shippable:

1. **Phase 0 — Spike (1–2 hours).** On a branch, swap just the backend
   middleware: keep email/password login, but verify Firebase tokens
   instead of looking up `user_sessions`. Validate the contract works.
   *Output:* confidence the swap is as small as we hope.
2. **Phase 1 — Backend cutover (~half day).** Land the schema migration,
   the new middleware, and a Firebase Admin client. Drop `user_sessions`.
   Update seed to create Firebase users via Admin SDK. Re-seed.
3. **Phase 2 — Flutter cutover (~half day).** Add Firebase Auth SDK +
   `firebase_core` to `pubspec.yaml`. Replace login screen logic. Wire
   `getIdToken()` into the API client's `tokenSupplier`. Test login,
   logout, restart-survival.
4. **Phase 3 — Signup + email verification + password reset
   (~half day).** Build the signup screen on top of the new auth. Wire
   `sendEmailVerification` + `sendPasswordResetEmail`. Update welcome
   screen — remove the "Create account (coming soon)" stub.
5. **Phase 4 — 2FA for staff accounts (optional, deferrable).** Owner +
   instructor roles get TOTP-based 2FA via Firebase's MFA APIs. Students
   skip.

Total cost to "signup works, password reset works": ~1.5–2 days of focused
work.

---

## Test plan

For each phase, the smoke we need to pass:

- [ ] Owen logs in, can hit `/disruptions` (existing httpapi test pattern).
- [ ] Owen logs out client-side, token rejected by backend within 1h.
- [ ] Student signs up via Open-mode school → lands in `/student`.
- [ ] Student signs up via Approval-mode school → lands on pending screen,
      Owen sees them in the Sign-ups queue.
- [ ] Forgot password from login screen → user receives email, resets,
      logs in.
- [ ] Disabled student in our `users` table → token still verifies but
      handler rejects with 403 (we keep `account_status` in our DB; not
      Firebase's job).
- [ ] All ~200 existing httpapi tests still pass (they use seed accounts,
      which the new seed creates via Firebase Admin).

---

## Decisions to make before kickoff

These are blocking — answer them, then we start:

1. **Firebase project ownership.** Whose Google account owns the Firebase
   project? Recommend a dedicated `kickstand@…` account, not a personal
   one. Project naming: `kickstand-dev`, `kickstand-prod`.
2. **Identity Platform vs Firebase Auth (free tier).** Firebase Auth has
   a hard cap at 50k MAU. Identity Platform unlocks higher tiers + SAML +
   multi-tenancy. **Recommendation:** start on Firebase Auth (free), can
   upgrade later without code changes.
3. **Multi-tenancy strategy.** Firebase has a built-in tenancy concept on
   Identity Platform. **Recommendation:** ignore it. Keep our existing
   `school_id` model — it's already working and Firebase tenancy adds
   complexity for ~zero benefit at our scale.
4. **Account merging.** Does `priya@lagan.test` (instructor) need to be the
   same user as `priya@example.com` (her personal Gmail if we ever add
   Sign in with Google)? **Recommendation:** no for v1. Each Firebase user
   = one human; multi-role users are a separate problem.
5. **Local dev — Firebase emulator or live project?** Live makes
   onboarding new devs annoying (everyone needs an account). Emulator
   means one extra `make` command and ~50MB of Java. **Recommendation:**
   emulator from day one, wire into the seed binary.
6. **Phone auth?** Skippable for v1 — email is enough. Defer until a
   customer asks.

---

## Paired work: receipt image storage

Decision **2026-06-07**: when we cut over to Firebase Auth we'll also wire
the receipt-image object store at the same time. Both live in the same
Google Cloud project and benefit from one configuration pass.

- Today the Reimbursements feature writes receipts to local disk
  (`./uploads/expenses/{id}/...`) via the `internal/filestore` interface.
- At Firebase cutover we add a `filestore.GCS` implementation pointing at
  the same Google Cloud Storage bucket as Firebase Storage uses. The
  database schema is unchanged — `receipt_storage_key` is just a different
  string format (a GCS object key instead of a filesystem path).
- Receipt serve endpoint (`GET /expenses/{id}/receipt`) keeps its
  auth-gated streaming. Once we want CDN delivery we can swap to signed
  URLs returned from the engine.

Net: ~30 lines of Go to add the GCS implementation, no schema changes, no
client changes. Treat as part of the same deploy cut.

## What this plan does NOT change

- The Go backend's overall shape, the tenant guard, the booking engine,
  the notify package, all of the Flutter app outside `state/auth.dart` +
  the login screen.
- The cost story for SQLite vs Postgres migration (separate decision).
- Any of the design / UI / UX work.
- The notification poll, the silent refresh, the refresh observer.

---

## Risks

- **Firebase outage during cutover.** Mitigation: keep the old code on a
  branch; rollback is `git revert + redeploy + restore migration`.
- **Token verification CPU cost.** `VerifyIDToken` does a JWT signature
  check on every request. Benchmarked at ~50µs on a Cloud Run instance —
  negligible vs the ~3ms our handlers already take. Not a real concern.
- **Local dev gotcha.** Forgetting to start the emulator means every login
  hits prod. Mitigation: `make run` checks for the emulator and warns; the
  client refuses to talk to prod from `localhost` in `--debug` mode.
- **Apple's "Sign in with Apple" requirement.** If we ever ship social
  login on iOS, Apple's review rules require Sign in with Apple alongside.
  Firebase supports it natively; just a couple lines. Defer.

---

## TL;DR for future-you

We're ~half a day of backend work + half a day of Flutter work from having
managed auth (incl. password reset, email verification, account lockout,
brute-force protection) instead of rolled-own. Zero migration cost because
we have no real users yet. Net code delta is roughly *flat* — we delete as
much as we add.

The blocker isn't engineering, it's the decisions in the section above.
Once those are answered, the work is mechanical.
