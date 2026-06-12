// Pure-Dart unit tests for decideRedirect — the function the
// GoRouter redirect callback delegates to. These tests prove the
// client-side gating: unauthenticated users can only see the auth
// pages, signed-in users can only see their own role's section.
//
// This is UX defence-in-depth. The Go API enforces the same policy
// server-side (see auth_coverage_test.go in the backend), so even if
// these checks regressed and an unauthorised user nav'd to
// /admin/students by typing the URL, every API call would still 401
// /403. But the redirect prevents the broken-UI experience of
// landing on an authed screen with no data.

import 'package:flutter_test/flutter_test.dart';
import 'package:kickstand/routing/router.dart';

String? decide({
  bool loading = false,
  bool signedIn = false,
  String? role,
  required String location,
}) =>
    decideRedirect(
      authLoading: loading,
      authSignedIn: signedIn,
      identityRole: role,
      location: location,
    );

void main() {
  group('decideRedirect: auth loading', () {
    test('loading + on /splash → stay', () {
      expect(decide(loading: true, location: '/splash'), isNull);
    });
    test('loading + elsewhere → bounce to /splash', () {
      expect(decide(loading: true, location: '/student'), '/splash');
      expect(decide(loading: true, location: '/admin/students'), '/splash');
      expect(decide(loading: true, location: '/welcome'), '/splash');
    });
  });

  group('decideRedirect: signed out', () {
    test('on /welcome → stay', () {
      expect(decide(location: '/welcome'), isNull);
    });
    test('on /login → stay', () {
      expect(decide(location: '/login'), isNull);
    });
    test('on /signup → stay', () {
      expect(decide(location: '/signup'), isNull);
    });
    test('on /splash → bounce to /welcome', () {
      // Splash is special — auth has resolved as not-signed-in, so we
      // shouldn't sit on the splash spinner.
      expect(decide(location: '/splash'), '/welcome');
    });
    test('on any protected route → bounce to /welcome', () {
      expect(decide(location: '/student'), '/welcome');
      expect(decide(location: '/instructor'), '/welcome');
      expect(decide(location: '/admin/students/abc'), '/welcome');
      expect(decide(location: '/notifications'), '/welcome');
    });
  });

  group('decideRedirect: signed in as student', () {
    test('on /student/* → stay', () {
      expect(decide(signedIn: true, role: 'student', location: '/student'), isNull);
      expect(decide(signedIn: true, role: 'student', location: '/student/browse'), isNull);
      expect(decide(signedIn: true, role: 'student', location: '/student/bookings'), isNull);
    });
    test('on auth pages → bounce to /student', () {
      for (final p in ['/welcome', '/login', '/signup', '/splash']) {
        expect(decide(signedIn: true, role: 'student', location: p), '/student',
            reason: 'auth page $p should bounce to student home');
      }
    });
    test('on /instructor/* → bounce to /student', () {
      expect(decide(signedIn: true, role: 'student', location: '/instructor'), '/student');
      expect(decide(signedIn: true, role: 'student', location: '/instructor/expenses'),
          '/student');
    });
    test('on /admin/* → bounce to /student', () {
      expect(decide(signedIn: true, role: 'student', location: '/admin'), '/student');
      expect(decide(signedIn: true, role: 'student', location: '/admin/students/abc'),
          '/student');
      expect(decide(signedIn: true, role: 'student', location: '/admin/reimbursements'),
          '/student');
    });
    test('on shared pages (/notifications) → stay', () {
      expect(decide(signedIn: true, role: 'student', location: '/notifications'), isNull);
    });
  });

  group('decideRedirect: signed in as instructor', () {
    test('on /instructor/* → stay', () {
      expect(decide(signedIn: true, role: 'instructor', location: '/instructor'), isNull);
      expect(decide(signedIn: true, role: 'instructor', location: '/instructor/expenses'),
          isNull);
    });
    test('on /student/* → bounce to /instructor', () {
      expect(decide(signedIn: true, role: 'instructor', location: '/student'),
          '/instructor');
      expect(decide(signedIn: true, role: 'instructor', location: '/student/bookings'),
          '/instructor');
    });
    test('on /admin/* → bounce to /instructor', () {
      expect(decide(signedIn: true, role: 'instructor', location: '/admin'),
          '/instructor');
      expect(decide(signedIn: true, role: 'instructor', location: '/admin/instructor-pay'),
          '/instructor');
    });
    test('on auth pages → bounce to /instructor', () {
      expect(decide(signedIn: true, role: 'instructor', location: '/welcome'),
          '/instructor');
    });
  });

  group('decideRedirect: signed in as admin', () {
    test('on /admin/* → stay', () {
      expect(decide(signedIn: true, role: 'admin', location: '/admin'), isNull);
      expect(decide(signedIn: true, role: 'admin', location: '/admin/students'), isNull);
      expect(decide(signedIn: true, role: 'admin', location: '/admin/reimbursements'),
          isNull);
    });
    test('on /student/* → bounce to /admin', () {
      expect(decide(signedIn: true, role: 'admin', location: '/student'), '/admin');
    });
    test('on /instructor/* → bounce to /admin', () {
      expect(decide(signedIn: true, role: 'admin', location: '/instructor'), '/admin');
    });
    test('on auth pages → bounce to /admin', () {
      expect(decide(signedIn: true, role: 'admin', location: '/welcome'), '/admin');
      expect(decide(signedIn: true, role: 'admin', location: '/login'), '/admin');
    });
  });

  group('decideRedirect: owner = same as admin', () {
    test('on /admin/* → stay', () {
      expect(decide(signedIn: true, role: 'owner', location: '/admin'), isNull);
      expect(decide(signedIn: true, role: 'owner', location: '/admin/instructors'),
          isNull);
    });
    test('on /student/* → bounce to /admin', () {
      expect(decide(signedIn: true, role: 'owner', location: '/student'), '/admin');
    });
  });
}
