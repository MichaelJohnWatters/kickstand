// Demo-mode ribbon — sits at the top of every shell when `kDemoMode`
// is true. Reminds visitors their changes won't persist; offers a
// "switch role" shortcut back to the role picker.
//
// In production builds `kDemoMode` is false and the widget renders
// SizedBox.shrink(), which the tree-shaker drops.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/demo_mode.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';

class DemoModeBanner extends ConsumerWidget {
  const DemoModeBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kDemoMode) return const SizedBox.shrink();
    return Material(
      color: const Color(0xFFFFF3D6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          const Icon(Icons.science_outlined, size: 16, color: KsColors.warning),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Demo mode — your changes aren\'t saved. Refresh to reset.',
              style: TextStyle(
                  color: KsColors.ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5),
            ),
          ),
          TextButton(
            onPressed: () {
              ref.read(demoRoleProvider.notifier).state = null;
              ref.read(authControllerProvider.notifier).clearDemoIdentity();
              context.go('/welcome');
            },
            style: TextButton.styleFrom(
              foregroundColor: KsColors.warning,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 28),
            ),
            child: const Text('Switch role'),
          ),
        ]),
      ),
    );
  }
}
