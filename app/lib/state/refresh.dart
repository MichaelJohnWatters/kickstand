// Cross-screen data freshness.
//
// Three signals trigger a silent background re-fetch:
//
//   1. The user navigates to a different shell tab. The new tab's providers
//      are invalidated; the cached values keep painting while the futures
//      re-run, so the user sees content immediately and any change pops in
//      a moment later. No spinner flash.
//
//   2. The app comes back to the foreground (`AppLifecycleState.resumed`).
//      We invalidate the curated "high-impact for this role" set.
//
//   3. The notification poll sees a new notification. Its category maps to
//      the set of providers that may now be stale.
//
// Adding a new shared provider? Add it to the relevant case in the
// `tabFor…` helpers below and (if a category implies it) in
// `_invalidateForCategory`. Keep the maps small — a missed invalidation is
// recoverable via pull-to-refresh, an over-eager one wastes battery.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notifications.dart';
import 'providers.dart';
import '../screens/admin_audit_screen.dart' show auditPageProvider;
import '../screens/admin_closures_screen.dart' show closuresProvider;
import '../screens/admin_master_calendar_screen.dart' show masterCalendarProvider;
import '../screens/browse_sessions_screen.dart' show sessionsProvider;
import '../screens/instructor_availability_screen.dart'
    show availabilitySlotsProvider, availabilityTimeOffProvider;
import '../screens/instructor_schedule_screen.dart' show scheduleSessionsProvider;
import '../screens/licence_screen.dart' show myProfileProvider, myTestsProvider;
import '../screens/my_bookings_screen.dart' show myBookingsProvider;
import '../screens/progress_screen.dart' show myProgressProvider;

/// Invalidate everything the destination tab might be showing. Called by
/// the shell whenever the active tab changes.
void refreshStudentTab(WidgetRef ref, String routePrefix) {
  if (routePrefix.startsWith('/student/browse')) {
    ref.invalidate(sessionsProvider);
    ref.invalidate(courseTypesProvider);
  } else if (routePrefix.startsWith('/student/bookings')) {
    ref.invalidate(myBookingsProvider('upcoming'));
    ref.invalidate(myBookingsProvider('past'));
  } else if (routePrefix.startsWith('/student/progress')) {
    ref.invalidate(myProgressProvider);
  } else if (routePrefix.startsWith('/student/licence')) {
    ref.invalidate(myProfileProvider);
    ref.invalidate(myTestsProvider);
  } else if (routePrefix == '/student') {
    // Home — pulls a bit of everything for the hero card / banners.
    ref.invalidate(myBookingsProvider('upcoming'));
    ref.invalidate(myProfileProvider);
  }
}

void refreshInstructorTab(WidgetRef ref, String routePrefix) {
  if (routePrefix.startsWith('/instructor/schedule') ||
      routePrefix == '/instructor') {
    ref.invalidate(scheduleSessionsProvider);
  } else if (routePrefix.startsWith('/instructor/availability')) {
    // Family-wide invalidation clears every cached instructor id at once.
    ref.invalidate(availabilitySlotsProvider);
    ref.invalidate(availabilityTimeOffProvider);
    ref.invalidate(locationsProvider);
  } else if (routePrefix.startsWith('/instructor/expenses')) {
    ref.invalidate(myExpensesProvider);
    ref.invalidate(expenseCategoriesProvider);
  }
  // Profile reads auth state only — nothing to invalidate.
}

void refreshAdminTab(WidgetRef ref, String routePrefix) {
  // Sidebar globals — kept fresh on every admin tick regardless of which
  // tab is showing, because they drive the always-visible nav badges.
  // Add new badge sources here, not under a per-tab branch.
  ref.invalidate(pendingSignupsProvider);
  ref.invalidate(openDisruptionsProvider);
  ref.invalidate(logisticsForDateProvider);
  ref.invalidate(fleetProvider);
  ref.invalidate(expensesForReviewProvider);
  ref.invalidate(openFollowupsProvider);

  if (routePrefix == '/admin' || routePrefix.startsWith('/admin/overview')) {
    ref.invalidate(fleetProvider);
    ref.invalidate(openDisruptionsProvider);
    ref.invalidate(logisticsForDateProvider);
    ref.invalidate(instructorsProvider);
  } else if (routePrefix.startsWith('/admin/calendar')) {
    ref.invalidate(masterCalendarProvider);
    ref.invalidate(locationsProvider);
  } else if (routePrefix.startsWith('/admin/students')) {
    ref.invalidate(studentsProvider);
  } else if (routePrefix.startsWith('/admin/signups')) {
    ref.invalidate(pendingSignupsProvider);
  } else if (routePrefix.startsWith('/admin/fleet')) {
    ref.invalidate(fleetProvider);
  } else if (routePrefix.startsWith('/admin/logistics')) {
    ref.invalidate(logisticsForDateProvider);
    ref.invalidate(fleetProvider);
  } else if (routePrefix.startsWith('/admin/disruptions')) {
    ref.invalidate(openDisruptionsProvider);
  } else if (routePrefix.startsWith('/admin/instructors')) {
    ref.invalidate(instructorsProvider);
    ref.invalidate(locationsProvider);
    ref.invalidate(courseTypesProvider);
  } else if (routePrefix.startsWith('/admin/locations')) {
    ref.invalidate(locationsProvider);
    ref.invalidate(travelTimesProvider);
  } else if (routePrefix.startsWith('/admin/courses')) {
    ref.invalidate(courseTypesProvider);
    ref.invalidate(courseTypesFullProvider);
  } else if (routePrefix.startsWith('/admin/instructor-pay')) {
    ref.invalidate(instructorPayOutstandingProvider);
  } else if (routePrefix.startsWith('/admin/reimbursements')) {
    ref.invalidate(expensesForReviewProvider);
    ref.invalidate(expenseCategoriesProvider);
  } else if (routePrefix.startsWith('/admin/compliance')) {
    ref.invalidate(complianceProvider);
  } else if (routePrefix.startsWith('/admin/finance')) {
    ref.invalidate(revenueProvider);
  } else if (routePrefix.startsWith('/admin/audit')) {
    ref.invalidate(auditPageProvider);
  } else if (routePrefix.startsWith('/admin/closures')) {
    ref.invalidate(closuresProvider);
  } else if (routePrefix.startsWith('/admin/incidents')) {
    ref.invalidate(openFollowupsProvider);
  }
  // Master calendar and Instructor pay use screen-local date/time-scoped
  // providers — they invalidate themselves on their internal pickers.
}

/// Mounted near the app root. Watches app lifecycle and the notifications
/// controller; fans out invalidations on resume / on new notifications.
class RefreshObserver extends ConsumerStatefulWidget {
  final Widget child;
  const RefreshObserver({required this.child, super.key});

  @override
  ConsumerState<RefreshObserver> createState() => _RefreshObserverState();
}

class _RefreshObserverState extends ConsumerState<RefreshObserver>
    with WidgetsBindingObserver {
  Set<String> _seenNotificationIds = {};
  bool _seededOnce = false;

  // Ambient refresh: while the app is foregrounded, fire a silent refetch
  // on a role-tuned interval. Riverpod dedupes concurrent in-flight
  // fetches and cached values keep painting, so the user perceives the
  // page as "live" without a spinner. No activity check — silent loads
  // are cheap and the user can't tell when one happens.
  //
  // Intervals reflect how stale each role's data realistically gets:
  //   - manager/owner sit on Overview / Disruptions and want near-realtime
  //   - instructors mostly mid-session, schedule rarely shifts under them
  //   - students browse occasionally; most changes arrive via notifications
  static const _intervalAdmin = Duration(seconds: 15);
  static const _intervalInstructor = Duration(seconds: 15);
  static const _intervalStudent = Duration(seconds: 30);
  Timer? _ambientTimer;
  DateTime _lastFiredAt = DateTime.now();
  bool _foregrounded = true;

  Duration _intervalForRole() {
    final role = ref.read(authControllerProvider).identity?.role;
    switch (role) {
      case 'student':
        return _intervalStudent;
      case 'instructor':
        return _intervalInstructor;
      case 'owner':
      case 'manager':
      case 'admin':
        return _intervalAdmin;
    }
    return _intervalAdmin;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Coarse 5s tick — the role-tuned interval gates whether we actually
    // refetch on a given tick. 5s keeps every per-role interval (15/30s)
    // landing on a tick boundary so the *advertised* interval matches
    // reality. One timer regardless of role; cheaper than recreating it
    // on login/logout role changes.
    _ambientTimer = Timer.periodic(const Duration(seconds: 5), _onTick);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ambientTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foregrounded = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) return;
    _lastFiredAt = DateTime.now();
    _refreshCurrentPage();
  }

  void _onTick(Timer _) {
    if (!_foregrounded) return;
    if (DateTime.now().difference(_lastFiredAt) < _intervalForRole()) return;
    final route = ref.read(currentRouteProvider);
    debugPrint('[refresh] ambient tick @ ${DateTime.now().toIso8601String()} '
        'route=$route interval=${_intervalForRole().inSeconds}s');
    _refreshCurrentPage();
    _lastFiredAt = DateTime.now();
  }

  /// Re-fetch only what the user is actually looking at right now. The
  /// per-shell `refreshXxxTab` helpers know each route's provider set, so
  /// an admin on Overview doesn't burn a request on student endpoints.
  void _refreshCurrentPage() {
    final route = ref.read(currentRouteProvider);
    if (route.startsWith('/admin')) {
      refreshAdminTab(ref, route);
    } else if (route.startsWith('/student')) {
      refreshStudentTab(ref, route);
    } else if (route.startsWith('/instructor')) {
      refreshInstructorTab(ref, route);
    }
  }

  void _invalidateForCategory(String category) {
    switch (category) {
      case 'booking':
        ref.invalidate(myBookingsProvider('upcoming'));
        ref.invalidate(myBookingsProvider('past'));
        ref.invalidate(scheduleSessionsProvider);
        ref.invalidate(sessionsProvider);
        ref.invalidate(fleetProvider);
        break;
      case 'disruption':
        ref.invalidate(openDisruptionsProvider);
        ref.invalidate(myBookingsProvider('upcoming'));
        ref.invalidate(fleetProvider);
        ref.invalidate(scheduleSessionsProvider);
        break;
      case 'payment':
        ref.invalidate(myProfileProvider);
        break;
      case 'reminder':
        // Reminders don't imply data changes — surface only.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Route comes from `currentRouteProvider`, pushed by each shell on
    // build. Trying to read GoRouterState from the MaterialApp.router
    // builder doesn't work — the router's inherited widget lives below.
    ref.listen(notificationsControllerProvider, (prev, next) {
      // First poll seeds the baseline so we don't fire invalidations for
      // notifications that already existed before the app opened.
      if (!_seededOnce) {
        _seededOnce = true;
        _seenNotificationIds = {for (final n in next.notifications) n.id};
        return;
      }
      final newCategories = <String>{};
      for (final n in next.notifications) {
        if (!_seenNotificationIds.contains(n.id)) {
          newCategories.add(n.category);
        }
      }
      _seenNotificationIds = {for (final n in next.notifications) n.id};
      for (final cat in newCategories) {
        _invalidateForCategory(cat);
      }
    });
    return widget.child;
  }
}
