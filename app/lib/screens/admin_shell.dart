// Admin shell — web-first sidebar with responsive drawer fallback.
//
// Desktop (≥ 900px): fixed 256px sidebar + main content area.
// Mobile/tablet:      AppBar with menu button → drawer.
//
// Sidebar holds: school header → nav items (some with badges) → user card.
// Active route highlighted by longest-prefix match on matchedLocation.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/providers.dart';
import '../state/refresh.dart';
import '../state/school.dart';
import '../theme/tokens.dart';

const _wideBreakpoint = 900.0;

/// Which live count (if any) feeds a nav item's badge. The tone-colour for
/// each source is decided in `_NavTile` — pick the source that matches the
/// nav item's purpose; severity colour follows.
enum BadgeSource {
  signups,         // pending self-signups awaiting approval
  disruptions,     // open bike-down events
  logistics,       // bikes that need to move for tomorrow
  fleetOffline,    // bikes currently offline
  reimbursements,  // instructor expenses awaiting review
}

class _NavItem {
  final String label;
  final IconData icon;
  final String route;
  final BadgeSource? badgeSource;
  const _NavItem({
    required this.label,
    required this.icon,
    required this.route,
    this.badgeSource,
  });
}

const _navItems = <_NavItem>[
  _NavItem(label: 'Overview', icon: Icons.dashboard_outlined, route: '/admin'),
  _NavItem(label: 'Master calendar', icon: Icons.calendar_month_outlined, route: '/admin/calendar'),
  _NavItem(label: 'Students', icon: Icons.school_outlined, route: '/admin/students'),
  _NavItem(label: 'Sign-ups', icon: Icons.person_add_outlined, route: '/admin/signups',
      badgeSource: BadgeSource.signups),
  _NavItem(label: 'Bike fleet', icon: Icons.two_wheeler, route: '/admin/fleet',
      badgeSource: BadgeSource.fleetOffline),
  _NavItem(label: 'Bike logistics', icon: Icons.local_shipping_outlined, route: '/admin/logistics',
      badgeSource: BadgeSource.logistics),
  _NavItem(label: 'Disruptions', icon: Icons.report_outlined, route: '/admin/disruptions',
      badgeSource: BadgeSource.disruptions),
  _NavItem(label: 'Instructors', icon: Icons.group_outlined, route: '/admin/instructors'),
  _NavItem(label: 'Instructor pay', icon: Icons.payments_outlined, route: '/admin/instructor-pay'),
  _NavItem(label: 'Reimbursements', icon: Icons.receipt_long_outlined, route: '/admin/reimbursements',
      badgeSource: BadgeSource.reimbursements),
  _NavItem(label: 'Locations', icon: Icons.place_outlined, route: '/admin/locations'),
  _NavItem(label: 'Course types', icon: Icons.menu_book_outlined, route: '/admin/courses'),
];

class AdminShell extends ConsumerStatefulWidget {
  final Widget child;
  const AdminShell({required this.child, super.key});

  @override
  ConsumerState<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends ConsumerState<AdminShell> {
  String? _lastRoute;

  String _activeRoute(BuildContext context) {
    final loc = GoRouterState.of(context).matchedLocation;
    for (int i = _navItems.length - 1; i >= 0; i--) {
      if (loc.startsWith(_navItems[i].route)) return _navItems[i].route;
    }
    return _navItems.first.route;
  }

  @override
  Widget build(BuildContext context) {
    final route = _activeRoute(context);
    // Publish the active route to the ambient RefreshObserver so its
    // timer ticks scope their invalidations correctly.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(currentRouteProvider.notifier).state = route;
    });
    // Tab switch → silent background refetch. Cached value paints; new
    // value swaps in when the future resolves.
    if (_lastRoute != route) {
      final previous = _lastRoute;
      _lastRoute = route;
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          refreshAdminTab(ref, route);
        });
      }
    }
    final wide = MediaQuery.of(context).size.width >= _wideBreakpoint;
    if (wide) {
      return Scaffold(
        backgroundColor: KsColors.bg,
        body: SelectionArea(
          child: Row(
            children: [
              const SizedBox(width: 256, child: _Sidebar(inDrawer: false)),
              Expanded(child: widget.child),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: Text(_currentLabel(context),
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 20)),
        backgroundColor: KsColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      drawer: const Drawer(
        backgroundColor: KsColors.surface,
        child: _Sidebar(inDrawer: true),
      ),
      body: SelectionArea(child: widget.child),
    );
  }

  String _currentLabel(BuildContext context) {
    final loc = GoRouterState.of(context).matchedLocation;
    for (int i = _navItems.length - 1; i >= 0; i--) {
      if (loc.startsWith(_navItems[i].route)) return _navItems[i].label;
    }
    return 'Admin';
  }
}

class _Sidebar extends ConsumerWidget {
  final bool inDrawer;
  const _Sidebar({required this.inDrawer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = GoRouterState.of(context).matchedLocation;
    final settings = ref.watch(schoolSettingsProvider).valueOrNull;
    final identity = ref.watch(authControllerProvider).identity;

    // Live badge counts. Each comes from a shared provider that the
    // ambient RefreshObserver invalidates every 15s, so every badge ticks
    // up / down without the manager doing anything.
    final pendingSignups = ref.watch(pendingSignupsCountProvider);

    final openDisruptions = ref
            .watch(openDisruptionsProvider)
            .maybeWhen(data: (l) => l.length, orElse: () => 0);

    final tomorrowMoves = ref.watch(tomorrowLogisticsProvider).maybeWhen(
          data: (m) => (m['totalMoves'] as num?)?.toInt() ?? 0,
          orElse: () => 0,
        );

    final offlineBikes = ref.watch(fleetProvider).maybeWhen(
          data: (bikes) => bikes.where((b) => b.status != 'ready').length,
          orElse: () => 0,
        );

    final pendingReimbursements = ref.watch(expensesForReviewProvider).maybeWhen(
          data: (p) => p.pendingCount,
          orElse: () => 0,
        );

    int countFor(BadgeSource? src) {
      switch (src) {
        case BadgeSource.signups:
          return pendingSignups;
        case BadgeSource.disruptions:
          return openDisruptions;
        case BadgeSource.logistics:
          return tomorrowMoves;
        case BadgeSource.fleetOffline:
          return offlineBikes;
        case BadgeSource.reimbursements:
          return pendingReimbursements;
        case null:
          return 0;
      }
    }

    return Container(
      decoration: const BoxDecoration(
        color: KsColors.surface,
        border: Border(right: BorderSide(color: KsColors.border)),
      ),
      child: Column(
        children: [
          // School header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: KsColors.primary,
                    borderRadius: BorderRadius.circular(KsRadius.sm),
                  ),
                  child: const Icon(Icons.two_wheeler, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        settings?.name ?? 'Kickstand',
                        style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 14, letterSpacing: -0.3),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        settings == null ? '' : '${settings.region} · ${settings.testBodyLabel}',
                        style: const TextStyle(color: KsColors.ink3, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: KsColors.border),

          // Nav
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              children: [
                for (final item in _navItems)
                  _NavTile(
                    item: item,
                    active: loc.startsWith(item.route) &&
                        (item.route == '/admin' ? loc == '/admin' : true),
                    badge: countFor(item.badgeSource),
                    onTap: () {
                      if (inDrawer) Navigator.of(context).pop();
                      context.go(item.route);
                    },
                  ),
              ],
            ),
          ),

          // User card
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: KsColors.border)),
            ),
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: KsColors.primaryTint,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                ),
                child: const Icon(Icons.person, color: KsColors.primaryDeep, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(identity?.name ?? '',
                        style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700, color: KsColors.ink, fontSize: 13)),
                    Text(_roleLabel(identity?.role ?? ''),
                        style: const TextStyle(color: KsColors.ink3, fontSize: 11)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Sign out',
                onPressed: () async {
                  await ref.read(authControllerProvider.notifier).logout();
                },
                icon: const Icon(Icons.logout, size: 18, color: KsColors.ink3),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  String _roleLabel(String r) {
    switch (r) {
      case 'owner':
        return 'Owner';
      case 'admin':
        return 'Admin';
      default:
        return r;
    }
  }
}

class _NavTile extends StatelessWidget {
  final _NavItem item;
  final bool active;
  final int badge;
  final VoidCallback onTap;
  const _NavTile({
    required this.item,
    required this.active,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.sm),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: active ? KsColors.primaryTint : Colors.transparent,
          borderRadius: BorderRadius.circular(KsRadius.sm),
        ),
        child: Row(
          children: [
            Icon(item.icon,
                size: 18,
                color: active ? KsColors.primaryDeep : KsColors.ink2),
            const SizedBox(width: 10),
            Expanded(
              child: Text(item.label,
                  style: GoogleFonts.plusJakartaSans(
                    fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    color: active ? KsColors.primaryDeep : KsColors.ink,
                    fontSize: 13,
                  )),
            ),
            if (badge > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _badgeColour(item.badgeSource),
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                ),
                child: Text('$badge',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }
}

// Severity colour per badge source — danger for "something's broken",
// warning for "needs action soon", primary for "queue length".
Color _badgeColour(BadgeSource? src) {
  switch (src) {
    case BadgeSource.disruptions:
    case BadgeSource.fleetOffline:
      return KsColors.danger;
    case BadgeSource.logistics:
    case BadgeSource.reimbursements:
      return KsColors.warning;
    case BadgeSource.signups:
    case null:
      return KsColors.primary;
  }
}

// Placeholder used by routes we haven't built yet — keeps navigation alive
// so the demo doesn't 404 on a nav click.
class AdminComingSoonScreen extends StatelessWidget {
  final String label;
  const AdminComingSoonScreen({required this.label, super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KsColors.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.construction_rounded, size: 56, color: KsColors.ink4),
              const SizedBox(height: 12),
              Text(label,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 17, fontWeight: FontWeight.w800, color: KsColors.ink)),
              const SizedBox(height: 4),
              const Text('Coming soon.', style: TextStyle(color: KsColors.ink2)),
            ],
          ),
        ),
      ),
    );
  }
}

