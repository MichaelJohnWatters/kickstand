// StudentShell — bottom tab bar across the student app.
//
// Routes go through this shell when they're under /student. The shell owns
// the BottomNavigationBar and swaps the child the router supplies.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/providers.dart';
import '../state/refresh.dart';
import '../theme/tokens.dart';

class StudentShell extends ConsumerStatefulWidget {
  final Widget child;
  const StudentShell({required this.child, super.key});

  static const _tabs = <_TabSpec>[
    _TabSpec(label: 'Home', icon: Icons.home_rounded, route: '/student'),
    _TabSpec(label: 'Book', icon: Icons.add_circle_outline_rounded, route: '/student/browse'),
    _TabSpec(label: 'Bookings', icon: Icons.event_note_rounded, route: '/student/bookings'),
    _TabSpec(label: 'Progress', icon: Icons.insights_rounded, route: '/student/progress'),
  ];

  @override
  ConsumerState<StudentShell> createState() => _StudentShellState();
}

class _StudentShellState extends ConsumerState<StudentShell> {
  int? _lastTab;

  int _activeIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    // Longest-prefix match — so '/student/bookings/cancel' still highlights
    // the Bookings tab.
    for (int i = StudentShell._tabs.length - 1; i >= 0; i--) {
      if (location.startsWith(StudentShell._tabs[i].route)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeIndex(context);
    final route = StudentShell._tabs[active].route;
    // Tell the ambient RefreshObserver which page we're on so its timer
    // ticks can scope their invalidations to this tab.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(currentRouteProvider.notifier).state = route;
    });
    // Tab switch → silent background refetch for the new tab's providers.
    // The cached value stays painted until the future resolves.
    if (_lastTab != active) {
      final previous = _lastTab;
      _lastTab = active;
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          refreshStudentTab(ref, route);
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
              children: List.generate(StudentShell._tabs.length, (i) {
                final t = StudentShell._tabs[i];
                final isActive = i == active;
                return Expanded(
                  child: InkWell(
                    onTap: () => context.go(t.route),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(t.icon,
                            color: isActive ? KsColors.primary : KsColors.ink3, size: 24),
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
