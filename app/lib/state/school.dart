// School settings provider — fetched once after login, cached. The
// in-field payment UI reads instructorsCanRecordPayments from here.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'providers.dart';

/// Cached for the life of the session. If settings change server-side
/// while the user's signed in, they pick up on next login.
final schoolSettingsProvider = FutureProvider<SchoolSettings>((ref) async {
  return ref.read(apiClientProvider).schoolSettings();
});
