// Kickstand — app entry. ProviderScope (Riverpod) wraps a MaterialApp.router
// fed by go_router.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routing/router.dart';
import 'state/refresh.dart';
import 'theme/theme.dart';

void main() {
  runApp(const ProviderScope(child: KickstandApp()));
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
