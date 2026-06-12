// Kickstand — app entry. ProviderScope (Riverpod) wraps a MaterialApp.router
// fed by go_router.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/client.dart';
import 'firebase_options.dart';
import 'routing/router.dart';
import 'state/auth.dart';
import 'state/demo_mode.dart';
import 'state/providers.dart';
import 'state/refresh.dart';
import 'theme/theme.dart';
import 'util/post_ready.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Demo builds skip Firebase entirely — no project ID, no network, no
  // Auth listener. AuthController detects kDemoMode and sits in
  // signed-out until the role picker fires (or a `?role=` query in
  // the page URL pre-selects it).
  if (!kDemoMode) {
    await _initFirebase();
  }
  final overrides = <Override>[];
  if (kDemoMode) {
    final preset = _roleFromUrl();
    if (preset != null) {
      // The marketing wrapper iframes us with `?role=...`. To skip the
      // in-app role picker entirely (otherwise it briefly flashes
      // before redirecting), preload the mock + start AuthController
      // already in signed-in state. The router then redirects from
      // /splash straight into the role's shell — no /welcome render.
      final mock = await MockApiClient.create(preset);
      final id = mock.demoIdentity();
      overrides.addAll([
        demoRoleProvider.overrideWith((_) => preset),
        apiClientProvider.overrideWithValue(mock),
        authControllerProvider.overrideWith(
          (ref) => AuthController(mock)..setDemoIdentity(id),
        ),
      ]);
    }
  }
  runApp(ProviderScope(overrides: overrides, child: const KickstandApp()));
  // Notify the marketing wrapper (when we're inside its iframe) that
  // the first frame has painted, so it can pull its overlay spinner.
  // No-op on mobile/desktop — see lib/util/post_ready.dart.
  WidgetsBinding.instance.addPostFrameCallback((_) => postReady());
}

/// Reads `?role=owner|instructor|student` from the page URL on web.
/// Returns null on mobile or when the query isn't present.
DemoRole? _roleFromUrl() {
  try {
    final v = Uri.base.queryParameters['role'];
    switch (v) {
      case 'owner':
      case 'admin':
        return DemoRole.owner;
      case 'instructor':
        return DemoRole.instructor;
      case 'student':
        return DemoRole.student;
    }
  } catch (_) {}
  return null;
}

// Initialise Firebase + wire the Auth emulator in debug builds.
//
// Phase 0: present but no widget in the app calls FirebaseAuth yet.
// Phase 3 of firebase-auth-migration.md flips the login screen + the
// AuthController onto this. Keeping the init here from day one means a
// future Phase 3 PR is purely additive — no main.dart churn.
Future<void> _initFirebase() async {
  await Firebase.initializeApp(options: kFirebaseOptions);
  if (kDebugMode) {
    // The emulator runs on localhost:19099 (see firebase.json / Makefile).
    // Non-default port to avoid clashing with other Firebase projects
    // already on this dev machine — Firebase's default Auth port is 9099.
    // In debug builds, every signInWith…/createUserWith… call routes here
    // instead of Google's servers — no real account, no network egress.
    await FirebaseAuth.instance.useAuthEmulator('localhost', 19099);
  }
}

class KickstandApp extends ConsumerWidget {
  const KickstandApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);
    return MaterialApp.router(
      title: 'Kickstand',
      debugShowCheckedModeBanner: false,
      theme: buildKsTheme(),
      routerConfig: router,
      // SelectionArea is mounted inside each shell's Scaffold body (below
      // the Navigator's Overlay) — that's the layer SelectionArea needs to
      // attach selection handles to. Putting it here would fail at startup
      // with "No Overlay widget found".
      builder: (context, child) =>
          RefreshObserver(child: child ?? const SizedBox()),
    );
  }
}

final _routerProvider = Provider((ref) => buildRouter(ref));
