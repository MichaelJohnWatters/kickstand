// go_router with auth-gate + role-aware redirect.
//
// Splash → /welcome (unauth) → /student or /instructor (auth, by role).
// ShellRoutes give each role its own bottom tab bar; routes outside the
// shell (booking review, notifications, session detail) are full-screen.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/admin_course_types_screen.dart';
import '../screens/admin_disruptions_screen.dart';
import '../screens/admin_fleet_screen.dart';
import '../screens/admin_instructor_pay_screen.dart';
import '../screens/admin_instructors_screen.dart';
import '../screens/admin_locations_screen.dart';
import '../screens/admin_analytics_screen.dart';
import '../screens/admin_gps_map_screen.dart';
import '../screens/admin_logistics_screen.dart';
import '../screens/admin_master_calendar_screen.dart';
import '../screens/admin_overview_screen.dart';
import '../screens/admin_reimbursements_screen.dart';
import '../screens/admin_bike_detail_screen.dart';
import '../screens/admin_audit_screen.dart';
import '../screens/admin_closures_screen.dart';
import '../screens/admin_incidents_screen.dart';
import '../screens/admin_compliance_screen.dart';
import '../screens/admin_finance_screen.dart';
import '../screens/admin_templates_screen.dart';
import '../screens/admin_settings_screen.dart';
import '../screens/demo_role_picker_screen.dart';
import '../screens/admin_shell.dart';
import '../screens/admin_signups_screen.dart';
import '../screens/admin_student_detail_screen.dart';
import '../screens/admin_students_screen.dart';
import '../screens/booking_confirmation_screen.dart';
import '../screens/browse_sessions_screen.dart';
import '../screens/instructor_assess_screen.dart';
import '../screens/instructor_availability_screen.dart';
import '../screens/instructor_expenses_screen.dart';
import '../screens/instructor_profile_screen.dart';
import '../screens/instructor_schedule_screen.dart';
import '../screens/instructor_session_detail_screen.dart';
import '../screens/instructor_shell.dart';
import '../screens/licence_screen.dart';
import '../screens/login_screen.dart';
import '../screens/signup_screen.dart';
import '../screens/my_bookings_screen.dart';
import '../screens/notification_prefs_screen.dart';
import '../screens/notifications_screen.dart';
import '../screens/progress_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/student_home_screen.dart';
import '../screens/student_shell.dart';
import '../screens/welcome_screen.dart';
import '../state/auth.dart';
import '../state/demo_mode.dart';
import '../state/providers.dart';

String _homeForRole(String role) {
  switch (role) {
    case 'instructor':
      return '/instructor';
    case 'admin':
    case 'owner':
      return '/admin';
    default:
      return '/student';
  }
}

bool _isStaff(String role) => role == 'admin' || role == 'owner';
bool _isStudent(String role) => role == 'student';
bool _isInstructor(String role) => role == 'instructor';

/// Pure-function form of the redirect policy — separated from the
/// GoRouter wiring so it can be unit-tested directly (see
/// test/router_redirect_test.dart).
///
/// Returns the location the user should be sent to, or null to allow
/// the requested route. The contract:
///
///   - Loading auth state: bounce everywhere except /splash to /splash.
///   - Signed out: only the auth pages (/welcome /login /signup) are
///     reachable; everything else lands at /welcome.
///   - Signed in: auth pages redirect to the role home.
///   - Signed in but trying to enter another role's section
///     (/student → /admin, etc.): bounce back to the role home.
///
/// The Go API enforces all of this server-side too (see
/// auth_coverage_test.go). The router redirect is UX polish, not the
/// security boundary.
String? decideRedirect({
  required bool authLoading,
  required bool authSignedIn,
  required String? identityRole,
  required String location,
}) {
  if (authLoading) {
    return location == '/splash' ? null : '/splash';
  }
  final isAuthPath = location == '/welcome' ||
      location == '/login' ||
      location == '/signup' ||
      location == '/splash';
  if (!authSignedIn) {
    return isAuthPath && location != '/splash' ? null : '/welcome';
  }
  final role = identityRole ?? 'student';
  final home = _homeForRole(role);
  if (isAuthPath) return home;
  final onStudent = location.startsWith('/student');
  final onInstructor = location.startsWith('/instructor');
  final onAdmin = location.startsWith('/admin');
  if (_isStudent(role) && !onStudent && (onInstructor || onAdmin)) return home;
  if (_isInstructor(role) && !onInstructor && (onStudent || onAdmin)) return home;
  if (_isStaff(role) && !onAdmin && (onStudent || onInstructor)) return home;
  return null;
}

GoRouter buildRouter(Ref ref) {
  final refresh = _RiverpodAuthRefresh(ref);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (ctx, state) {
      final auth = ref.read(authControllerProvider);
      return decideRedirect(
        authLoading: auth.loading,
        authSignedIn: auth.isSignedIn,
        identityRole: auth.identity?.role,
        location: state.matchedLocation,
      );
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
      // Auth flow uses NoTransitionPage — the Material default fade is
      // ~300ms which reads as "lag" when tapping the welcome screen's
      // "I already have an account" button. Same fix as the tab routes.
      GoRoute(
          path: '/welcome',
          pageBuilder: (_, __) => _instant(kDemoMode
              ? const DemoRolePickerScreen()
              : const WelcomeScreen())),
      GoRoute(path: '/login', pageBuilder: (_, __) => _instant(const LoginScreen())),
      GoRoute(path: '/signup', pageBuilder: (_, __) => _instant(const SignupScreen())),

      // Shared between roles.
      GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
      GoRoute(path: '/notifications/prefs', builder: (_, __) => const NotificationPrefsScreen()),

      // Student shell. Tab switches use NoTransitionPage so the navigation
      // feels instant on web — Material's default fade-in transition is the
      // bulk of the perceived "tab lag" otherwise.
      ShellRoute(
        builder: (ctx, state, child) => StudentShell(child: child),
        routes: [
          GoRoute(path: '/student', pageBuilder: (_, __) => _instant(const StudentHomeScreen())),
          GoRoute(path: '/student/browse', pageBuilder: (_, __) => _instant(const BrowseSessionsScreen())),
          GoRoute(path: '/student/bookings', pageBuilder: (_, __) => _instant(const MyBookingsScreen())),
          GoRoute(path: '/student/progress', pageBuilder: (_, __) => _instant(const ProgressScreen())),
          GoRoute(path: '/student/licence', pageBuilder: (_, __) => _instant(const LicenceScreen())),
        ],
      ),
      // Confirmation lands outside the shell so the success view is
      // full-bleed (no tab bar). The 4-step booking flow itself lives in
      // BrowseSessionsScreen — there's no per-session route any more.
      GoRoute(
        path: '/student/confirmed/:bookingId',
        builder: (ctx, st) => BookingConfirmationScreen(bookingId: st.pathParameters['bookingId']!),
      ),

      // Instructor shell. Same NoTransitionPage treatment as the other tab bars.
      ShellRoute(
        builder: (ctx, state, child) => InstructorShell(child: child),
        routes: [
          GoRoute(path: '/instructor', pageBuilder: (_, __) => _instant(const InstructorScheduleScreen())),
          GoRoute(path: '/instructor/availability', pageBuilder: (_, __) => _instant(const InstructorAvailabilityScreen())),
          GoRoute(path: '/instructor/expenses', pageBuilder: (_, __) => _instant(const InstructorExpensesScreen())),
          GoRoute(path: '/instructor/profile', pageBuilder: (_, __) => _instant(const InstructorProfileScreen())),
        ],
      ),
      GoRoute(
        path: '/instructor/session/:sessionId',
        builder: (ctx, st) => InstructorSessionDetailScreen(sessionId: st.pathParameters['sessionId']!),
      ),
      GoRoute(
        path: '/instructor/session/:sessionId/assess/:bookingId',
        builder: (ctx, st) => InstructorAssessScreen(
          sessionId: st.pathParameters['sessionId']!,
          bookingId: st.pathParameters['bookingId']!,
        ),
      ),

      // Admin shell (web-first). Sidebar nav clicks should feel instant —
      // see _instant() helper below.
      ShellRoute(
        builder: (ctx, state, child) => AdminShell(child: child),
        routes: [
          GoRoute(path: '/admin', pageBuilder: (_, __) => _instant(const AdminOverviewScreen())),
          GoRoute(path: '/admin/signups', pageBuilder: (_, __) => _instant(const AdminSignupsScreen())),
          GoRoute(path: '/admin/students', pageBuilder: (_, __) => _instant(const AdminStudentsScreen())),
          GoRoute(
            path: '/admin/students/:id',
            pageBuilder: (ctx, st) => _instant(AdminStudentDetailScreen(studentId: st.pathParameters['id']!)),
          ),
          GoRoute(path: '/admin/fleet', pageBuilder: (_, __) => _instant(const AdminFleetScreen())),
          GoRoute(
            path: '/admin/fleet/:bikeId',
            pageBuilder: (ctx, st) => _instant(
              AdminBikeDetailScreen(bikeId: st.pathParameters['bikeId']!),
            ),
          ),
          GoRoute(path: '/admin/disruptions', pageBuilder: (_, __) => _instant(const AdminDisruptionsScreen())),
          GoRoute(path: '/admin/logistics', pageBuilder: (_, __) => _instant(const AdminLogisticsScreen())),
          GoRoute(path: '/admin/gps', pageBuilder: (_, __) => _instant(const AdminGpsMapScreen())),
          GoRoute(path: '/admin/analytics', pageBuilder: (_, __) => _instant(const AdminAnalyticsScreen())),
          GoRoute(path: '/admin/instructors', pageBuilder: (_, __) => _instant(const AdminInstructorsScreen())),
          GoRoute(path: '/admin/instructor-pay', pageBuilder: (_, __) => _instant(const AdminInstructorPayScreen())),
          GoRoute(path: '/admin/reimbursements', pageBuilder: (_, __) => _instant(const AdminReimbursementsScreen())),
          GoRoute(path: '/admin/locations', pageBuilder: (_, __) => _instant(const AdminLocationsScreen())),
          GoRoute(path: '/admin/courses', pageBuilder: (_, __) => _instant(const AdminCourseTypesScreen())),
          GoRoute(path: '/admin/calendar', pageBuilder: (_, __) => _instant(const AdminMasterCalendarScreen())),
          GoRoute(path: '/admin/audit', pageBuilder: (_, __) => _instant(const AdminAuditScreen())),
          GoRoute(path: '/admin/compliance', pageBuilder: (_, __) => _instant(const AdminComplianceScreen())),
          GoRoute(path: '/admin/finance', pageBuilder: (_, __) => _instant(const AdminFinanceScreen())),
          GoRoute(path: '/admin/templates', pageBuilder: (_, __) => _instant(const AdminTemplatesScreen())),
          GoRoute(path: '/admin/closures', pageBuilder: (_, __) => _instant(const AdminClosuresScreen())),
          GoRoute(path: '/admin/incidents', pageBuilder: (_, __) => _instant(const AdminIncidentsScreen())),
          GoRoute(path: '/admin/settings', pageBuilder: (_, __) => _instant(const AdminSettingsScreen())),
        ],
      ),
    ],
  );
}

/// Page wrapper that skips the default Material fade transition — tab
/// switches inside a shell should feel like a router state change, not a
/// page push. Used across all three role shells.
NoTransitionPage<void> _instant(Widget child) =>
    NoTransitionPage<void>(child: child);

/// Bridges Riverpod's authState into GoRouter's refreshListenable.
class _RiverpodAuthRefresh extends ChangeNotifier {
  late final ProviderSubscription<AuthState> _sub;
  _RiverpodAuthRefresh(Ref ref) {
    _sub = ref.listen<AuthState>(authControllerProvider, (_, __) => notifyListeners());
  }
  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}
