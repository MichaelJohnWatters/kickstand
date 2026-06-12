// Role picker — the demo-mode landing screen.
//
// Replaces /welcome when `kDemoMode` is true (see router.dart). Three
// tiles map onto our three role shells. Clicking one:
//   1. Sets `demoRoleProvider` so the MockApiClient rebuilds with the
//      right /me payload.
//   2. Awaits the new MockApiClient.
//   3. Pins the demo identity in AuthController.
//   4. Navigates to the role's home route.
//
// Tree-shaken out of production builds because `kDemoMode` is a const.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/client.dart';
import '../state/demo_mode.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';

class DemoRolePickerScreen extends ConsumerStatefulWidget {
  const DemoRolePickerScreen({super.key});
  @override
  ConsumerState<DemoRolePickerScreen> createState() => _DemoRolePickerScreenState();
}

class _DemoRolePickerScreenState extends ConsumerState<DemoRolePickerScreen> {
  @override
  void initState() {
    super.initState();
    // If the URL pre-selected a role (the marketing wrapper iframes us
    // with ?role=...), skip the picker entirely and jump straight into
    // that shell. A microtask delay lets the ProviderScope finish
    // wiring before we read the provider + fire navigation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final preset = ref.read(demoRoleProvider);
      if (preset != null) {
        _pick(context, ref, preset);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KsColors.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (ctx, c) {
            final wide = c.maxWidth >= 800;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: KsColors.primary,
                            borderRadius: BorderRadius.circular(KsRadius.sm),
                          ),
                          child: const Icon(Icons.two_wheeler, color: Colors.white, size: 22),
                        ),
                        const SizedBox(width: 10),
                        Text('Kickstand',
                            style: GoogleFonts.plusJakartaSans(
                              color: KsColors.ink,
                              fontWeight: FontWeight.w800,
                              fontSize: 20,
                              letterSpacing: -0.4,
                            )),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: KsColors.warningTint,
                            borderRadius: BorderRadius.circular(KsRadius.pill),
                          ),
                          child: const Text('DEMO',
                              style: TextStyle(
                                  color: KsColors.warning,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 11)),
                        ),
                      ]),
                      const SizedBox(height: 28),
                      Text(
                        'Pick a role to try Kickstand',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: KsColors.ink,
                            letterSpacing: -1.0),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Each role sees a different app. Your changes won\'t be saved — '
                        'refresh to start over.',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 16,
                            color: KsColors.ink3,
                            height: 1.4),
                      ),
                      const SizedBox(height: 28),
                      wide
                          ? Row(children: [
                              Expanded(child: _RoleCard.owner(onPick: _pick)),
                              const SizedBox(width: 14),
                              Expanded(child: _RoleCard.instructor(onPick: _pick)),
                              const SizedBox(width: 14),
                              Expanded(child: _RoleCard.student(onPick: _pick)),
                            ])
                          : Column(children: [
                              _RoleCard.owner(onPick: _pick),
                              const SizedBox(height: 12),
                              _RoleCard.instructor(onPick: _pick),
                              const SizedBox(height: 12),
                              _RoleCard.student(onPick: _pick),
                            ]),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static Future<void> _pick(BuildContext context, WidgetRef ref, DemoRole role) async {
    // Setting the role rebuilds the apiClientProvider's FutureProvider,
    // which materialises a MockApiClient pre-seeded for that role.
    ref.read(demoRoleProvider.notifier).state = role;
    // Loading spinner while the seed loads (it's fast — a few hundred KB).
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      // Force a read on the (now-fresh) provider; wait for it to
      // materialise. Importing the private demo provider isn't possible
      // — pump the public apiClientProvider until it resolves to the
      // mock by yielding a microtask + a frame.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final client = ref.read(apiClientProvider);
      if (client is! MockApiClient) {
        // Still loading — wait briefly and retry.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final mock = ref.read(apiClientProvider);
      if (mock is MockApiClient) {
        ref.read(authControllerProvider.notifier)
            .setDemoIdentity(mock.demoIdentity());
      }
    } finally {
      if (context.mounted) Navigator.of(context).pop();
    }
    if (!context.mounted) return;
    switch (role) {
      case DemoRole.owner:
        context.go('/admin');
        break;
      case DemoRole.instructor:
        context.go('/instructor');
        break;
      case DemoRole.student:
        context.go('/student');
        break;
    }
  }
}

class _RoleCard extends ConsumerWidget {
  final DemoRole role;
  final String title;
  final String name;
  final String blurb;
  final IconData icon;
  final List<String> bullets;
  final Color accent;
  final Future<void> Function(BuildContext, WidgetRef, DemoRole) onPick;

  const _RoleCard({
    required this.role,
    required this.title,
    required this.name,
    required this.blurb,
    required this.icon,
    required this.bullets,
    required this.accent,
    required this.onPick,
  });

  factory _RoleCard.owner({required Future<void> Function(BuildContext, WidgetRef, DemoRole) onPick}) =>
      _RoleCard(
        role: DemoRole.owner,
        title: 'Owner / Manager',
        name: 'Owen',
        blurb: 'The whole school in one sidebar.',
        icon: Icons.dashboard_customize_outlined,
        accent: const Color(0xFF6366F1),
        bullets: [
          'Master calendar + bike fleet',
          'MOT/tax/mileage, gov.uk lookups',
          'Reimbursements & instructor pay',
          'Settings to tune the whole school',
        ],
        onPick: onPick,
      );

  factory _RoleCard.instructor({required Future<void> Function(BuildContext, WidgetRef, DemoRole) onPick}) =>
      _RoleCard(
        role: DemoRole.instructor,
        title: 'Instructor',
        name: 'Dave',
        blurb: 'Tomorrow\'s lessons, in your pocket.',
        icon: Icons.school_outlined,
        accent: const Color(0xFFF59E0B),
        bullets: [
          'Today + future schedule',
          'Mark attendance & competencies',
          'Snap receipts to claim expenses',
          'Manage your weekly availability',
        ],
        onPick: onPick,
      );

  factory _RoleCard.student({required Future<void> Function(BuildContext, WidgetRef, DemoRole) onPick}) =>
      _RoleCard(
        role: DemoRole.student,
        title: 'Student',
        name: 'Alex',
        blurb: 'Book your training in a few taps.',
        icon: Icons.directions_bike_outlined,
        accent: const Color(0xFF10B981),
        bullets: [
          'Browse available sessions',
          'Live progress + competency map',
          'See your training pad on a map',
          'Outstanding balance + payments',
        ],
        onPick: onPick,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: KsColors.surface,
      borderRadius: BorderRadius.circular(KsRadius.lg),
      child: InkWell(
        onTap: () => onPick(context, ref, role),
        borderRadius: BorderRadius.circular(KsRadius.lg),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            border: Border.all(color: KsColors.border),
            borderRadius: BorderRadius.circular(KsRadius.lg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(KsRadius.md),
                ),
                child: Icon(icon, color: accent, size: 26),
              ),
              const SizedBox(height: 14),
              Text(title,
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: KsColors.ink)),
              Text('View as $name',
                  style: TextStyle(color: accent, fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(height: 8),
              Text(blurb,
                  style: const TextStyle(
                      color: KsColors.ink2, fontSize: 13.5, height: 1.4)),
              const SizedBox(height: 14),
              for (final b in bullets)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.check_circle, size: 14, color: KsColors.success),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(b,
                          style: const TextStyle(
                              color: KsColors.ink2,
                              fontSize: 12.5,
                              height: 1.35)),
                    ),
                  ]),
                ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: Text('Enter →',
                    style: TextStyle(
                        color: accent, fontWeight: FontWeight.w800, fontSize: 14)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
