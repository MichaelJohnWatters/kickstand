// Demo-mode plumbing.
//
// `kDemoMode` is a compile-time const fed by `--dart-define=KS_DEMO_MODE=true`
// at build time. Production builds default to false and the entire demo
// code path is tree-shaken out of the bundle. Don't change to a runtime
// flag without good reason.
//
// The role picker writes into `demoRoleProvider`; AuthController +
// apiClientProvider both read from it.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';

const bool kDemoMode = bool.fromEnvironment('KS_DEMO_MODE', defaultValue: false);

/// The role the demo visitor picked. `null` means "haven't picked yet"
/// — the router redirect uses that to send them to the role picker.
final demoRoleProvider = StateProvider<DemoRole?>((ref) => null);
