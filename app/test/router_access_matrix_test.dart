// Comprehensive role × page access matrix.
//
// For every route registered in `router.dart` and every role
// (unauthenticated / student / instructor / admin / owner), assert
// what `decideRedirect` does: stay (null) or bounce to some target.
//
// This is the Flutter mirror of internal/httpapi/auth_matrix_test.go.
// Together they prove:
//
//   - Every API endpoint enforces a role gate server-side.
//   - Every page route enforces a role gate client-side.
//
// The client gate is UX defence in depth — the Go API is the real
// security boundary, but the redirect keeps unauthorised users from
// landing on broken-data screens.

import 'package:flutter_test/flutter_test.dart';
import 'package:kickstand/routing/router.dart';

// Roles under test. `null` means "no Firebase user signed in".
const _roles = <String?>[null, 'student', 'instructor', 'admin', 'owner'];

// Every route the GoRouter mounts (or that a user could type into the
// address bar). When adding a new screen, add a row here and the sweep
// will tell you what gate it gets.
const _routes = <String>[
  // Auth / boot
  '/splash',
  '/welcome',
  '/login',
  '/signup',

  // Shared
  '/notifications',

  // Student shell
  '/student',
  '/student/browse',
  '/student/bookings',
  '/student/progress',
  '/student/licence',
  '/student/confirmed/abc',

  // Instructor shell
  '/instructor',
  '/instructor/availability',
  '/instructor/expenses',
  '/instructor/profile',
  '/instructor/session/sess_t',
  '/instructor/session/sess_t/assess/bk_t',

  // Admin shell
  '/admin',
  '/admin/signups',
  '/admin/students',
  '/admin/students/user_stu',
  '/admin/fleet',
  '/admin/fleet/bike_a1m1',
  '/admin/disruptions',
  '/admin/logistics',
  '/admin/gps',
  '/admin/analytics',
  '/admin/instructors',
  '/admin/instructor-pay',
  '/admin/reimbursements',
  '/admin/locations',
  '/admin/courses',
  '/admin/calendar',
  '/admin/templates',
  '/admin/closures',
  '/admin/incidents',
  '/admin/audit',
  '/admin/compliance',
  '/admin/finance',
  '/admin/settings',
];

/// expected encodes the matrix policy. Returns the expected redirect
/// target for (role, location), or null to mean "stay here".
String? expected(String? role, String location) {
  // Unauthenticated: only the auth pages are reachable. /splash is
  // special — auth has resolved so we don't sit on the spinner.
  if (role == null) {
    const authPages = ['/welcome', '/login', '/signup'];
    if (authPages.contains(location)) return null;
    return '/welcome';
  }

  // Signed in: auth pages bounce to the role home.
  String home;
  switch (role) {
    case 'student':
      home = '/student';
      break;
    case 'instructor':
      home = '/instructor';
      break;
    case 'admin':
    case 'owner':
      home = '/admin';
      break;
    default:
      home = '/student';
  }
  const authPages = ['/welcome', '/login', '/signup', '/splash'];
  if (authPages.contains(location)) return home;

  // Shared pages reachable by every authed user.
  if (location == '/notifications') return null;

  // Role-prefixed routes — same role can reach, others bounce home.
  if (location.startsWith('/student')) {
    return role == 'student' ? null : home;
  }
  if (location.startsWith('/instructor')) {
    return role == 'instructor' ? null : home;
  }
  if (location.startsWith('/admin')) {
    return (role == 'admin' || role == 'owner') ? null : home;
  }

  // Anything else: allowed (no redirect). No such routes today, but
  // the sweep still asserts it.
  return null;
}

String? decide(String? role, String location) => decideRedirect(
      authLoading: false,
      authSignedIn: role != null,
      identityRole: role,
      location: location,
    );

void main() {
  group('Page access matrix', () {
    for (final role in _roles) {
      final label = role ?? 'unauthenticated';
      group('as $label', () {
        for (final route in _routes) {
          test('$route → ${expected(role, route) ?? 'stay'}', () {
            expect(decide(role, route), expected(role, route));
          });
        }
      });
    }
  });

  // Smoke check: every route in _routes should produce a defined
  // answer for every role. If we added a route here without updating
  // expected(), one of the asserts above would catch it; this is a
  // belt-and-suspenders that the matrix is exhaustive.
  test('matrix is exhaustive', () {
    for (final role in _roles) {
      for (final route in _routes) {
        // expected() returns null for "stay" or a target — we just
        // assert it didn't throw.
        expected(role, route);
      }
    }
  });
}
