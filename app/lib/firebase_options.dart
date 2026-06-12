// Firebase project config.
//
// Phase 0 — hand-rolled to point at the `kickstand-dev` emulator project.
// These values don't need to be real Firebase API keys: the emulator
// accepts anything as long as `projectId` matches `.firebaserc`.
//
// When we provision real Firebase projects (Phase 1 or Phase 6), run
// `flutterfire configure --project=kickstand-dev` to regenerate this
// file with platform-specific options. Keep the same `kFirebaseOptions`
// name so callers don't need to change.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

/// Emulator-only placeholder options. Safe to commit because the values
/// are not real credentials and only resolve against the local emulator.
const FirebaseOptions kFirebaseOptions = FirebaseOptions(
  apiKey: 'kickstand-dev-emulator-key',
  appId: '1:000000000000:android:0000000000000000000000',
  messagingSenderId: '000000000000',
  projectId: 'kickstand-dev',
);
