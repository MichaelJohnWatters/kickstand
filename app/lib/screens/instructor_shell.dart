// Instructor bottom tab bar — Schedule / Profile. Availability comes later.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/providers.dart';
import '../state/refresh.dart';
import '../theme/tokens.dart';

class InstructorShell extends ConsumerStatefulWidget {
  final Widget child;
  const InstructorShell({required this.child, super.key});

  static const _tabs = <_TabSpec>[
    _TabSpec(label: 'Schedule', icon: Icons.calendar_today_rounded, route: '/instructor'),
    _TabSpec(label: 'Availability', icon: Icons.access_time_rounded, route: '/instructor/availability'),
    _TabSpec(label: 'Expenses', icon: Icons.receipt_long_rounded, route: '/instructor/expenses'),
    _TabSpec(label: 'Profile', icon: Icons.person_rounded, route: '/instructor/profile'),
  ];

  @override
  ConsumerState<InstructorShell> createState() => _InstructorShellState();
}

class _InstructorShellState extends ConsumerState<InstructorShell> {
  int? _lastTab;

  int _activeIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    for (int i = InstructorShell._tabs.length - 1; i >= 0; i--) {
      if (location.startsWith(InstructorShell._tabs[i].route)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeIndex(context);
    final route = InstructorShell._tabs[active].route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(currentRouteProvider.notifier).state = route;
    });
    if (_lastTab != active) {
      final previous = _lastTab;
      _lastTab = active;
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          refreshInstructorTab(ref, route);
        });
      }
    }
    return Scaffold(
      backgroundColor: KsColors.bg,
      body: SelectionArea(child: widget.child),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: KsColors.surface,
          border: Border(top: BorderSide(color: KsColors.border)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(
              children: List.generate(InstructorShell._tabs.length, (i) {
                final t = InstructorShell._tabs[i];
                final isActive = i == active;
                return Expanded(
                  child: InkWell(
                    onTap: () => context.go(t.route),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(t.icon, color: isActive ? KsColors.primary : KsColors.ink3, size: 24),
                        const SizedBox(height: 2),
                        Text(t.label,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 11,
                              fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                              color: isActive ? KsColors.primary : KsColors.ink3,
                            )),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabSpec {
  final String label;
  final IconData icon;
  final String route;
  const _TabSpec({required this.label, required this.icon, required this.route});
}
