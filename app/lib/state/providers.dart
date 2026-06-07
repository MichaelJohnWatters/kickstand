// Riverpod providers — the dependency-injection seam for the whole app.
//
// `apiBaseUrl` defaults to localhost:8765 for `flutter run -d chrome`
// against a `make run` Go server. (Port 8765 chosen to avoid Tilt / Prom /
// Adminer / other common dev tools that grab 8080.) Override at build time:
//   flutter run -d chrome --dart-define=KS_API_BASE_URL=https://api.kickstand.test

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'auth.dart';
import 'token_storage.dart';

const _defaultBaseUrl = String.fromEnvironment(
  'KS_API_BASE_URL',
  defaultValue: 'http://localhost:8765',
);

final tokenStorageProvider = Provider<TokenStorage>((_) => TokenStorage());

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(baseUrl: _defaultBaseUrl, tokenSupplier: () => null);
});

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>((ref) {
  final api = ref.read(apiClientProvider);
  final store = ref.read(tokenStorageProvider);
  return AuthController(api, store);
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
