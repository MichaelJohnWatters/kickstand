# Kickstand — Flutter client

One Flutter codebase serving all three Kickstand roles across iOS, Android, and
Flutter Web. A logged-in user is one role in one tenant; `go_router` runs an
auth-gate + role redirect that sends them to `/student`, `/instructor`, or
`/admin` and bounces cross-role URLs back home.

For the backend, the full build status, and the design spec, see the
[repo root README](../README.md), [`STATUS.md`](../STATUS.md), and
[`design_handoff_kickstand/`](../design_handoff_kickstand/).

## Architecture

- **Routing** — `go_router`, auth-gate + role-based redirect
- **State** — Riverpod
- **HTTP** — Dio; a typed `ApiException` carries a stable `code` so screens branch
  on `capacity_full` vs `no_suitable_bike` etc. for friendly copy
- **Auth** — `firebase_auth`; uses the Auth emulator in debug builds
- **Tokens** — `flutter_secure_storage` (Keychain / Keystore on mobile,
  localStorage on web)
- **Type** — `google_fonts` for Plus Jakarta Sans + Space Mono

Good files to orient from:
- `lib/routing/router.dart` — the route map (the whole screen list at a glance)
- `lib/api/client.dart` — the HTTP surface area
- `lib/state/providers.dart` — providers + the `KS_API_BASE_URL` default

## Run

The client expects the Go backend and Firebase Auth emulator running — see
["Run it" in the root README](../README.md#run-it). From the repo root:

```bash
make app-deps                 # flutter pub get
make app-run                  # Chrome by default; override: make app-run DEVICE=ios
make app-analyze              # static analysis
make app-web                  # release web build → app/build/web
```

API base defaults to `http://localhost:8765`. Override at build/run time:

```bash
flutter run -d chrome --dart-define=KS_API_BASE_URL=https://api.example.com
```

## Demo mode

Built with `--dart-define=KS_DEMO_MODE=true`, the app swaps `apiClientProvider` for
a `MockApiClient` that serves JSON fixtures from `assets/demo/` — no backend, no
Firebase. Writes are accepted optimistically in memory; a refresh resets. This is
what ships in `dist/marketing/` as the embeddable sales demo. Build it with
`make web-demo` (see [`demo-mode-plan.md`](../demo-mode-plan.md)).
