# Firebase setup (pilot blocker D)

Kickstand uses Firebase Authentication. Everything to date has only run against
the local Auth **emulator** — a real deployment needs a real Firebase project.
This is the one-time setup. Repeat it per **dedicated** instance that wants its
own isolated user pool (a dedicated customer can have their own project — same
steps, different project, that project's env on that instance).

## How the app uses Firebase (so the steps make sense)

- **Backend** (`internal/auth`): verifies incoming ID tokens with the Admin SDK
  and, during `provision`, *creates* the owner's Firebase user. Needs a
  **service-account JSON** + `FIREBASE_PROJECT_ID`.
- **Flutter client** (`app/lib/main.dart`, `firebase_options.dart`): signs users
  in, registers them (`createUserWithEmailAndPassword`), and sends password-reset
  emails via the Firebase client SDK. Needs the **web/app config** + the web
  **authorized domain**. In debug builds it points at the emulator; release
  builds use the real config.

## Steps

1. **Create the project** — <https://console.firebase.google.com> → Add project.
   Note the **Project ID** (e.g. `kickstand-prod`).

2. **Enable Email/Password** — Authentication → Sign-in method → enable the
   **Email/Password** provider. (That's the only method the app uses.)

3. **Authorized domains** — Authentication → Settings → Authorized domains → add
   the web app's domain (e.g. `app.kickstand.example`). `localhost` is already
   listed for dev.

4. **Password-reset email template** — Authentication → Templates → Password
   reset. Set the sender name and action URL to your domain. (Password reset was
   the reason auth moved to Firebase — make sure this email looks right.)

5. **Service account for the backend** — Project settings → Service accounts →
   **Generate new private key** → download the JSON. On the server set:
   ```
   FIREBASE_PROJECT_ID=<your project id>
   GOOGLE_APPLICATION_CREDENTIALS=/secrets/firebase-sa.json   # path in the container
   ```
   In Docker, drop the file at `deploy/secrets/firebase-sa.json` (gitignored;
   mounted read-only at `/secrets`). **Never commit it.**

6. **Client config for the web build** — Project settings → Your apps → add a
   **Web app** (and iOS/Android apps if you ship those). Then replace the
   emulator placeholders in `app/lib/firebase_options.dart` with the real values
   — easiest via the FlutterFire CLI:
   ```
   dart pub global activate flutterfire_cli
   cd app && flutterfire configure --project=<your project id>
   ```
   Release builds then talk to the real project; debug builds still use the
   emulator (guarded by `kDebugMode` in `main.dart`).

7. **(Optional) App Check** — register providers per platform and enforce later;
   deferred for the pilot (the signup rate-limit covers basic abuse).

## Verify

- **Backend config** — set the two env vars and run the smoke check:
  ```
  FIREBASE_PROJECT_ID=... GOOGLE_APPLICATION_CREDENTIALS=/abs/path/sa.json \
    make firebase-smoke
  ```
  It boots the server on a throwaway DB and confirms it comes up
  **firebase-enabled (production credentials)** and `/readyz` returns 200. That
  proves the project + creds load (the common misconfig). Full token
  verification is exercised by an actual login below.

- **End to end** — provision the first owner against the real project:
  ```
  FIREBASE_PROJECT_ID=... GOOGLE_APPLICATION_CREDENTIALS=/abs/path/sa.json \
    bin/provision -dsn /data/kickstand.db -name "Pilot School" -region NI \
    -owner-email you@example.com -owner-name "You" -owner-password '...'
  ```
  Then sign in as that owner through the web app — a successful login means the
  client config, authorized domain, and backend token verification all line up.

## Cost

Firebase Authentication's email/password tier is free at pilot volumes; no
billing setup is required for auth itself.
