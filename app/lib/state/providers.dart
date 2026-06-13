// Riverpod providers — the dependency-injection seam for the whole app.
//
// `apiBaseUrl` defaults to localhost:8765 for `flutter run -d chrome`
// against a `make run` Go server. (Port 8765 chosen to avoid Tilt / Prom /
// Adminer / other common dev tools that grab 8080.) Override at build time:
//   flutter run -d chrome --dart-define=KS_API_BASE_URL=https://api.kickstand.test

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'auth.dart';
import 'demo_mode.dart';

const _defaultBaseUrl = String.fromEnvironment(
  'KS_API_BASE_URL',
  defaultValue: 'http://localhost:8765',
);

/// Bearer token comes from Firebase Auth post-cutover. The SDK caches
/// the ID token in process memory and on disk (Keychain/Keystore on
/// mobile, IndexedDB on web), and `getIdToken()` refreshes it silently
/// when it's within a few minutes of expiry — so callers don't have to
/// retry on 401.
final apiClientProvider = Provider<ApiClient>((ref) {
  if (kDemoMode) {
    // Demo build — the FutureProvider below loads canned JSON assets
    // and swaps the override in. Until that resolves the first call
    // sees the placeholder ApiClient that throws on use.
    final mock = ref.watch(_demoApiClientProvider).valueOrNull;
    if (mock != null) return mock;
  }
  return ApiClient(
    baseUrl: _defaultBaseUrl,
    tokenSupplier: () async {
      return await FirebaseAuth.instance.currentUser?.getIdToken();
    },
  );
});

/// Demo-mode boot: load every JSON dump into a MockApiClient. Tied to
/// the picked role so flipping the role picker rebuilds with the
/// right `/me`. Production code never reads this — `kDemoMode` is
/// false so tree-shaking drops the whole branch.
final _demoApiClientProvider = FutureProvider<MockApiClient>((ref) async {
  final role = ref.watch(demoRoleProvider) ?? DemoRole.owner;
  return MockApiClient.create(role);
});

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController(ref.read(apiClientProvider));
});

/// Carries the most recent successful booking from the review step to the
/// confirmation screen — saves the second round-trip and lets us surface
/// advisories the engine returned with the booking.
final lastBookingProvider = StateProvider<BookingResult?>((_) => null);

/// Active shell route, set by each shell on every rebuild. The ambient
/// `RefreshObserver` watches this to know which page's providers to
/// re-fetch on its timer ticks. Kept here (not in refresh.dart) so the
/// shells don't have to import the refresh module.
final currentRouteProvider = StateProvider<String>((_) => '/');

/// Fleet, open disruptions, and tomorrow's logistics are read from multiple
/// admin screens (Overview, Fleet, Disruptions, Logistics). Hoisting them
/// here keeps a single cache: when any screen invalidates the provider after
/// a mutation, every consumer re-fetches. Without this, taking a bike
/// offline on the Fleet screen would leave the Overview showing stale
/// "Bikes ready" counts.
final fleetProvider = FutureProvider<List<FleetBike>>((ref) async {
  return ref.read(apiClientProvider).listFleet();
});

/// Bike GPS snapshots for the live-map screen. Auto-disposed because
/// the screen polls on its own ambient timer (refresh.dart) and we
/// don't want a stale list sitting in cache for other screens.
final bikeGpsProvider = FutureProvider.autoDispose<List<BikeGPS>>((ref) async {
  return ref.read(apiClientProvider).listBikeGPS();
});

/// Per-bike GPS breadcrumb trail. Auto-disposed and family-keyed by
/// bike id so each selected bike fetches independently and clears
/// when the user closes the detail card.
final bikeGpsHistoryProvider =
    FutureProvider.autoDispose.family<List<GpsFix>, String>((ref, bikeId) {
  // Last 24h is enough to read recent movements without paging.
  final since = DateTime.now().toUtc().subtract(const Duration(hours: 24));
  return ref.read(apiClientProvider).listBikeGPSHistory(
        bikeId: bikeId,
        since: since,
      );
});

/// Analytics window state — drives all three sections on the
/// /admin/analytics page. Single source of truth so the numbers
/// across cards always agree.
class AnalyticsWindow {
  final DateTime from;
  final DateTime to;
  const AnalyticsWindow({required this.from, required this.to});

  factory AnalyticsWindow.last30Days() {
    final now = DateTime.now().toUtc();
    return AnalyticsWindow(from: now.subtract(const Duration(days: 30)), to: now);
  }
}

final analyticsWindowProvider =
    StateProvider<AnalyticsWindow>((_) => AnalyticsWindow.last30Days());

final bikeUtilisationProvider =
    FutureProvider.autoDispose<List<BikeUtilisationRow>>((ref) async {
  final w = ref.watch(analyticsWindowProvider);
  return ref.read(apiClientProvider).analyticsBikeUtilisation(from: w.from, to: w.to);
});

final instructorUtilisationProvider =
    FutureProvider.autoDispose<List<InstructorUtilisationRow>>((ref) async {
  final w = ref.watch(analyticsWindowProvider);
  return ref.read(apiClientProvider).analyticsInstructorUtilisation(from: w.from, to: w.to);
});

final funnelStatsProvider = FutureProvider.autoDispose<FunnelStats>((ref) async {
  final w = ref.watch(analyticsWindowProvider);
  return ref.read(apiClientProvider).analyticsFunnel(from: w.from, to: w.to);
});

/// Per-category notification prefs. Auto-disposed since it's only
/// read on the prefs screen; the dispatcher gate lives server-side.
final notificationPrefsProvider =
    FutureProvider.autoDispose<List<NotificationPrefs>>((ref) async {
  return ref.read(apiClientProvider).getNotificationPrefs();
});

/// Student's active waitlist entries. Read from My Bookings to render
/// the "you're waiting on these" section. Long-lived so leaving a
/// waitlist or auto-promotion can invalidate from anywhere.
final myWaitlistProvider = FutureProvider<List<MyWaitlistEntry>>((ref) async {
  return ref.read(apiClientProvider).listMyWaitlist();
});

final openDisruptionsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.read(apiClientProvider).listDisruptions(openOnly: true);
});

/// Logistics for a given calendar day, keyed by `YYYY-MM-DD` so the same
/// cache feeds Overview ("tomorrow") and the Logistics screen (any date the
/// admin picks). Invalidating the family clears all keys.
final logisticsForDateProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, dateKey) async {
  final parts = dateKey.split('-');
  final date = DateTime.utc(
      int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  return ref.read(apiClientProvider).logistics(date: date);
});

/// Convenience format: today / tomorrow as `YYYY-MM-DD`.
String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Tomorrow-anchored shortcut used by Overview's KPI / "needs attention"
/// card. Reads via the shared family so the logistics screen and Overview
/// share one network request for the same date.
final tomorrowLogisticsProvider =
    Provider<AsyncValue<Map<String, dynamic>>>((ref) {
  final tomorrow = DateTime.now().add(const Duration(days: 1));
  return ref.watch(logisticsForDateProvider(dateKey(tomorrow)));
});

/// Pending sign-ups list — read by the Sign-ups screen and (as a derived count)
/// by the sidebar badge. Approving / rejecting invalidates this provider so
/// both consumers refresh in lockstep.
final pendingSignupsProvider =
    FutureProvider<List<PendingApplicant>>((ref) async {
  return ref.read(apiClientProvider).listPendingSignups();
});

/// Rejected sign-ups — disabled student accounts with no booking
/// history, so the admin can review past rejections (and restore the
/// occasional accidental click).
final rejectedSignupsProvider =
    FutureProvider<List<PendingApplicant>>((ref) async {
  return ref.read(apiClientProvider).listRejectedSignups();
});

/// Approved sign-ups — students approved in the last 7 days, newest
/// first. Lets the manager grab the phone number to call them after
/// approving without hunting through the full Students list.
final approvedSignupsProvider =
    FutureProvider<List<PendingApplicant>>((ref) async {
  return ref.read(apiClientProvider).listApprovedSignups();
});

/// Sidebar badge count, derived from [pendingSignupsProvider] so the badge
/// always tracks the list without a second network round-trip.
final pendingSignupsCountProvider = Provider<int>((ref) {
  return ref.watch(pendingSignupsProvider).maybeWhen(
        data: (l) => l.length,
        orElse: () => 0,
      );
});

/// Students list (parameterised by server-side `q` search). Approving a
/// sign-up invalidates the whole family so any cached search refreshes.
final studentsProvider =
    FutureProvider.family<List<StudentRow>, String>((ref, q) async {
  return ref.read(apiClientProvider).listStudents(q: q);
});

/// Instructors list — read by Overview KPI, Instructors editor, Course-types
/// quals lists, Instructor pay summaries.
final instructorsProvider = FutureProvider<List<InstructorRow>>((ref) async {
  return ref.read(apiClientProvider).listInstructors();
});

/// Locations list — referenced by Locations matrix, Instructor availability,
/// Fleet (home/current names), Sign-ups school settings. Any add / rename
/// invalidates this.
final locationsProvider = FutureProvider<List<LocationLite>>((ref) async {
  return ref.read(apiClientProvider).listLocations();
});

/// Travel-time matrix — pairs of (from, to, minutes). Read by the Locations
/// matrix and by the master-calendar's tight-travel detector once we wire it.
/// Editing a cell or adding a location invalidates this so the matrix
/// repaints with the new pair.
final travelTimesProvider = FutureProvider<List<TravelTime>>((ref) async {
  return ref.read(apiClientProvider).listTravelTimes();
});

/// Course types (lite) — used wherever we need an id/name list.
final courseTypesProvider = FutureProvider<List<CourseTypeLite>>((ref) async {
  return ref.read(apiClientProvider).listCourseTypes();
});

/// Course types (full shape) — used by the Course-types editor screen.
/// Hoisted so silent tab-refresh + invalidations from create/update/delete
/// hit the same cache the editor reads. The lite variant above stays in
/// sync because every mutation invalidates both.
final courseTypesFullProvider =
    FutureProvider<List<CourseTypeFull>>((ref) async {
  return ref.read(apiClientProvider).listCourseTypesFull();
});

/// Instructor-pay outstanding rows — drives the Instructor pay hero +
/// per-instructor cards.
final instructorPayOutstandingProvider =
    FutureProvider<List<InstructorPayRow>>((ref) async {
  return ref.read(apiClientProvider).listInstructorPayOutstanding();
});

/// Reimbursable expense categories (per-school list). Read by the
/// instructor "Add expense" form and the admin "Manage types" modal.
final expenseCategoriesProvider =
    FutureProvider<List<ExpenseCategory>>((ref) async {
  return ref.read(apiClientProvider).listExpenseCategories();
});

/// The current instructor's expenses (every state). Drives the instructor
/// Expenses tab and the outstanding-total hero.
final myExpensesProvider =
    FutureProvider<MyExpensesPayload>((ref) async {
  return ref.read(apiClientProvider).listMyExpenses();
});

/// Admin review queue + pending count. Drives the Reimbursements page
/// table, the KPIs, and the sidebar badge.
final expensesForReviewProvider =
    FutureProvider<ExpensesQueuePayload>((ref) async {
  return ref.read(apiClientProvider).listExpensesForReview();
});

/// Compliance dashboard payload. Non-autoDispose so the tab paints
/// cached data immediately on re-entry and the silent-refresh cycle
/// in `refresh.dart` updates it in the background.
final complianceProvider = FutureProvider<ComplianceReport>((ref) async {
  return ref.read(apiClientProvider).getCompliance();
});

/// Finance overview (monthly billed/collected, ageing, by-course).
final revenueProvider = FutureProvider<RevenueReport>((ref) async {
  return ref.read(apiClientProvider).getRevenue();
});

/// School-wide open incident follow-ups (with open/overdue counts).
/// Drives the /admin/incidents page and the overview badge in one
/// call so the two surfaces never disagree.
class OpenFollowupsPayload {
  final List<Map<String, dynamic>> followups;
  final int open;
  final int overdue;
  const OpenFollowupsPayload({
    required this.followups,
    required this.open,
    required this.overdue,
  });
}

final openFollowupsProvider =
    FutureProvider<OpenFollowupsPayload>((ref) async {
  final res = await ref.read(apiClientProvider).listOpenFollowups();
  return OpenFollowupsPayload(
    followups: res.followups,
    open: res.open,
    overdue: res.overdue,
  );
});
