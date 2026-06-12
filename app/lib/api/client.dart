// Dio HTTP client with a bearer-token interceptor.
//
// The token is supplied via a getter so it can change at runtime (login /
// logout) without rebuilding the client. Errors from the Go server come
// back as {"error": code, "message": text} — the response interceptor
// unwraps them into ApiException so callers branch on a stable code.
//
// `mock_api_client.dart` is `part of` this library so MockApiClient can
// override the private `_send` seam without leaking private API to the
// rest of the app.

library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'models.dart';

part 'mock_api_client.dart';

class ApiClient {
  final Dio _dio;

  /// Async because Firebase's `getIdToken()` is async. The Dio interceptor
  /// awaits this before sending; widget code that needs a sync value (e.g.
  /// `Image.network` headers for receipts) reads `currentToken()`, which
  /// returns the most-recently-cached token from this supplier.
  Future<String?> Function() _tokenSupplier;
  String? _cachedToken;

  ApiClient({required String baseUrl, required Future<String?> Function() tokenSupplier})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          contentType: 'application/json',
          // Don't throw on 4xx — we handle those by inspecting the body.
          validateStatus: (s) => s != null && s < 500,
        )),
        _tokenSupplier = tokenSupplier {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final t = await _tokenSupplier();
        _cachedToken = t;
        if (t != null && t.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $t';
        }
        handler.next(options);
      },
    ));
  }

  /// Replace the token supplier — kept exported so test harnesses can
  /// stub it without rebuilding the client.
  void setTokenSupplier(Future<String?> Function() s) {
    _tokenSupplier = s;
  }

  /// Internal helper: every public API method funnels through this so error
  /// handling stays consistent.
  ///
  /// Network-level failures (server down, timeout, DNS, no internet) come
  /// out of Dio as `DioException`. We never let that type escape this file —
  /// it's mapped to an `ApiException` with a stable code and a human
  /// message so screens can display a friendly line instead of a stack
  /// trace.
  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? query,
  }) async {
    Response<dynamic> res;
    try {
      res = await _dio.request<dynamic>(
        path,
        data: data,
        queryParameters: query,
        options: Options(method: method),
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
    if (res.statusCode != null && res.statusCode! >= 400) {
      final body = res.data;
      if (body is Map<String, dynamic>) {
        throw ApiException(
          res.statusCode!,
          body['error']?.toString() ?? 'unknown',
          body['message']?.toString() ?? 'Something went wrong.',
        );
      }
      throw ApiException(
          res.statusCode ?? 0, 'unknown', 'Something went wrong.');
    }
    return res;
  }

  /// Translate Dio's transport-layer errors into our typed ApiException with
  /// a friendly human message. Screens can branch on `code` for special
  /// handling (e.g. retry button) and otherwise just display `message`.
  ApiException _mapDioException(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
        return ApiException(0, 'network_unreachable',
            'Can’t reach the server. Check your connection and try again.');
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException(0, 'timeout',
            'The server took too long to respond. Try again in a moment.');
      case DioExceptionType.cancel:
        return ApiException(0, 'cancelled', 'Request cancelled.');
      case DioExceptionType.badCertificate:
        return ApiException(0, 'bad_certificate',
            'Couldn’t verify the server’s identity.');
      case DioExceptionType.badResponse:
        // 5xx that slipped past validateStatus, or a malformed payload Dio
        // refused to decode. Prefer the server's message if it sent one.
        final body = e.response?.data;
        final status = e.response?.statusCode ?? 0;
        if (body is Map<String, dynamic>) {
          return ApiException(
            status,
            body['error']?.toString() ?? 'server_error',
            body['message']?.toString() ??
                'The server hit an error. Try again in a moment.',
          );
        }
        return ApiException(
            status, 'server_error', 'The server hit an error. Try again in a moment.');
      case DioExceptionType.unknown:
        return ApiException(0, 'network_error',
            'Couldn’t complete that request. Check your connection.');
    }
  }

  // ----- Auth -----
  //
  // Login + logout live in Firebase Auth post-cutover. Flutter calls
  // `FirebaseAuth.signInWithEmailAndPassword` / `signOut()` directly,
  // and the AuthController watches `authStateChanges()`. The only
  // server endpoint we still hit during sign-in is /me, to load the
  // school_id + role from our local users row.

  /// GET /schools — public catalog for the signup picker. No auth.
  Future<List<SchoolLite>> listSchools() async {
    final res = await _send('GET', '/schools');
    return ((res.data as Map<String, dynamic>)['schools'] as List? ?? const [])
        .map((e) => SchoolLite.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /auth/firebase-signup — runs after the Flutter side has called
  /// `FirebaseAuth.createUserWithEmailAndPassword`. The JWT sent in the
  /// Authorization header proves the UID; the body carries the rest of
  /// the profile we own. Returns the resulting [Identity].
  Future<Identity> firebaseSignup({
    required String schoolId,
    required String name,
    required String email,
    String? phone,
    String? transmissionPreference,
    String? licenceCategoryPursued,
    String? dateOfBirth,
  }) async {
    final res = await _send('POST', '/auth/firebase-signup', data: {
      'schoolId': schoolId,
      'name': name,
      'email': email,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (transmissionPreference != null && transmissionPreference.isNotEmpty)
        'transmissionPreference': transmissionPreference,
      if (licenceCategoryPursued != null && licenceCategoryPursued.isNotEmpty)
        'licenceCategoryPursued': licenceCategoryPursued,
      if (dateOfBirth != null && dateOfBirth.isNotEmpty) 'dateOfBirth': dateOfBirth,
    });
    return Identity.fromJson(
      (res.data as Map<String, dynamic>)['identity'] as Map<String, dynamic>,
    );
  }

  Future<Identity> me() async {
    final res = await _send('GET', '/me');
    return Identity.fromJson(res.data as Map<String, dynamic>);
  }

  // ----- Sessions / bookings -----

  /// Sessions in [from, to). Times are sent as UTC RFC3339; server returns
  /// honest (bike-aware) capacity per session.
  Future<List<SessionListing>> listSessions({
    required DateTime from,
    required DateTime to,
    String? locationId,
  }) async {
    final res = await _send('GET', '/sessions', query: {
      'from': from.toUtc().toIso8601String(),
      'to': to.toUtc().toIso8601String(),
      if (locationId != null) 'locationId': locationId,
    });
    final list = ((res.data as Map<String, dynamic>)['sessions'] as List? ?? const [])
        .map((e) => SessionListing.fromJson(e as Map<String, dynamic>))
        .toList();
    return list;
  }

  /// Lists the bikes the engine would accept for [sessionId]. Used by the
  /// booking flow's bike-picker step. For students, the server filters by
  /// the caller's transmission preference; for staff, no transmission
  /// filter is applied.
  Future<List<SuitableBike>> suitableBikesForSession(String sessionId) async {
    final res = await _send('GET', '/sessions/$sessionId/suitable-bikes');
    return ((res.data as Map<String, dynamic>)['bikes'] as List? ?? const [])
        .map((e) => SuitableBike.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<BookingResult> book({required String sessionId, String? bikeId, String? studentId}) async {
    final res = await _send('POST', '/bookings', data: {
      'sessionId': sessionId,
      if (bikeId != null) 'bikeId': bikeId,
      if (studentId != null) 'studentId': studentId,
    });
    return BookingResult.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /bookings/{id}/assign-bike — admin swaps the bike on a
  /// booking. Backs the master-calendar edit sheet's per-row "Swap
  /// bike" picker. Throws on 409 bike_not_suitable so the caller can
  /// surface a friendly error.
  Future<void> assignBookingBike({
    required String bookingId,
    required String bikeId,
  }) async {
    await _send('POST', '/bookings/$bookingId/assign-bike',
        data: {'bikeId': bikeId});
  }

  Future<Booking> cancelBooking(String bookingId, {String? reason}) async {
    final res = await _send('DELETE', '/bookings/$bookingId',
        data: reason == null ? null : {'reason': reason});
    final body = res.data as Map<String, dynamic>;
    return Booking.fromJson(body['booking'] ?? const {});
  }

  /// /me/bookings — list the caller's own bookings. when = 'upcoming' |
  /// 'past' | '' (all).
  Future<List<MyBooking>> listMyBookings({String when = ''}) async {
    final res = await _send('GET', '/me/bookings',
        query: when.isEmpty ? null : {'when': when});
    return ((res.data as Map<String, dynamic>)['bookings'] as List? ?? const [])
        .map((e) => MyBooking.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// /me/student-profile — the caller's licence/CBT/theory facts.
  Future<StudentProfile> myStudentProfile() async {
    final res = await _send('GET', '/me/student-profile');
    return StudentProfile.fromJson(res.data as Map<String, dynamic>);
  }

  /// /students/{id}/progress — per-course competency rollup.
  Future<List<CourseProgress>> studentProgress(String studentId) async {
    final res = await _send('GET', '/students/$studentId/progress');
    return ((res.data as Map<String, dynamic>)['courses'] as List? ?? const [])
        .map((e) => CourseProgress.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// /students/{id}/tests — DVA/DVSA test history.
  Future<List<ExternalTest>> studentTests(String studentId) async {
    final res = await _send('GET', '/students/$studentId/tests');
    return ((res.data as Map<String, dynamic>)['tests'] as List? ?? const [])
        .map((e) => ExternalTest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ----- Notifications -----

  Future<NotificationList> listNotifications({int limit = 50, bool unreadOnly = false}) async {
    final res = await _send('GET', '/me/notifications', query: {
      'limit': '$limit',
      if (unreadOnly) 'unread': 'true',
    });
    return NotificationList.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> markNotificationRead(String id) async {
    await _send('POST', '/me/notifications/$id/read');
  }

  Future<void> markAllNotificationsRead() async {
    await _send('POST', '/me/notifications/read-all');
  }

  // ----- Instructor: calendar + session detail -----

  /// /calendar — for instructors auto-scopes to their own sessions.
  Future<List<Map<String, dynamic>>> calendar({
    required DateTime from,
    required DateTime to,
    String? instructorId,
    String? locationId,
    String? courseTypeId,
  }) async {
    final body = await calendarFull(
      from: from,
      to: to,
      instructorId: instructorId,
      locationId: locationId,
      courseTypeId: courseTypeId,
    );
    return ((body['sessions'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  /// Same as [calendar] but returns the full body including 'warnings'. The
  /// master calendar wants both; legacy callers can keep using [calendar].
  Future<Map<String, dynamic>> calendarFull({
    required DateTime from,
    required DateTime to,
    String? instructorId,
    String? locationId,
    String? courseTypeId,
    bool includeCancelled = false,
  }) async {
    final res = await _send('GET', '/calendar', query: {
      'from': from.toUtc().toIso8601String(),
      'to': to.toUtc().toIso8601String(),
      if (instructorId != null && instructorId.isNotEmpty) 'instructorId': instructorId,
      if (locationId != null && locationId.isNotEmpty) 'locationId': locationId,
      if (courseTypeId != null && courseTypeId.isNotEmpty) 'courseTypeId': courseTypeId,
      if (includeCancelled) 'includeCancelled': 'true',
    });
    return res.data as Map<String, dynamic>;
  }

  /// /sessions/{id}/detail — the instructor screen payload.
  Future<Map<String, dynamic>> sessionDetail(String sessionId) async {
    final res = await _send('GET', '/sessions/$sessionId/detail');
    return res.data as Map<String, dynamic>;
  }

  /// POST /bookings/{id}/attendance — status must be 'completed' or 'no_show'.
  Future<void> markAttendance({required String bookingId, required String status}) async {
    await _send('POST', '/bookings/$bookingId/attendance', data: {'status': status});
  }

  /// PUT /bookings/{id}/competencies/{compId} — status must be
  /// 'not_assessed' | 'developing' | 'competent' | 'needs_work'.
  Future<void> assessCompetency({
    required String bookingId,
    required String competencyId,
    required String status,
  }) async {
    await _send('PUT', '/bookings/$bookingId/competencies/$competencyId', data: {'status': status});
  }

  /// PUT /bookings/{id}/notes — replaces the booking's per-booking notes.
  Future<void> setBookingNotes({required String bookingId, required String notes}) async {
    await _send('PUT', '/bookings/$bookingId/notes', data: {'notes': notes});
  }

  // ----- School settings + in-field payments -----

  /// GET /school — readable by any authenticated user. Includes the
  /// instructorsCanRecordPayments toggle the assess screen needs.
  Future<SchoolSettings> schoolSettings() async {
    final res = await _send('GET', '/school');
    return SchoolSettings.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /students/{id}/payments — instructor records a payment in the
  /// field. The server stamps recorded_by from the bearer token; it
  /// returns 403 if the school toggle is off.
  Future<int> recordStudentPayment({
    required String studentId,
    required int amountPence,
    required String method, // 'cash' | 'bank_transfer' | 'card_in_person' | 'other'
    String? notes,
  }) async {
    final res = await _send('POST', '/students/$studentId/payments', data: {
      'amountPence': amountPence,
      'method': method,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    });
    final body = res.data as Map<String, dynamic>;
    return (body['newBalance'] as int?) ?? 0;
  }

  // ----- Locations (read-only consumer view) -----

  /// /locations — any authed user can read. Backed-by handleListLocations
  /// which returns admin.Location structs (note: snake-case differs from
  /// camel-case on some fields; LocationLite.fromJson handles both).
  Future<List<LocationLite>> listLocations() async {
    final res = await _send('GET', '/locations');
    return ((res.data as Map<String, dynamic>)['locations'] as List? ?? const [])
        .map((e) => LocationLite.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ----- Availability + time-off -----

  Future<List<RecurringSlot>> listRecurringSlots(String instructorId) async {
    final res = await _send('GET', '/instructors/$instructorId/availability');
    return ((res.data as Map<String, dynamic>)['slots'] as List? ?? const [])
        .map((e) => RecurringSlot.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<RecurringSlot> createRecurringSlot({
    required String instructorId,
    required int weekday,
    required String startsAtLocal, // 'HH:MM'
    required String endsAtLocal,   // 'HH:MM'
    String? locationId,
  }) async {
    final res = await _send('POST', '/instructors/$instructorId/availability', data: {
      'weekday': weekday,
      'startsAtLocal': startsAtLocal,
      'endsAtLocal': endsAtLocal,
      if (locationId != null && locationId.isNotEmpty) 'locationId': locationId,
    });
    return RecurringSlot.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteRecurringSlot(String slotId) async {
    await _send('DELETE', '/availability/$slotId');
  }

  Future<List<TimeOff>> listTimeOff(String instructorId) async {
    final res = await _send('GET', '/instructors/$instructorId/time-off');
    return ((res.data as Map<String, dynamic>)['timeOff'] as List? ?? const [])
        .map((e) => TimeOff.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<TimeOff> createTimeOff({
    required String instructorId,
    required DateTime startsAt,
    required DateTime endsAt,
    String? reason,
  }) async {
    final res = await _send('POST', '/instructors/$instructorId/time-off', data: {
      'startsAt': startsAt.toUtc().toIso8601String(),
      'endsAt': endsAt.toUtc().toIso8601String(),
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
    return TimeOff.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteTimeOff(String id) async {
    await _send('DELETE', '/time-off/$id');
  }

  // ----- Admin: sign-ups -----

  Future<List<PendingApplicant>> listPendingSignups() async {
    final res = await _send('GET', '/signups/pending');
    return ((res.data as Map<String, dynamic>)['applicants'] as List? ?? const [])
        .map((e) => PendingApplicant.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> approveSignup(String userId) async {
    await _send('POST', '/signups/$userId/approve');
  }

  Future<void> rejectSignup(String userId) async {
    await _send('POST', '/signups/$userId/reject');
  }

  Future<List<PendingApplicant>> listRejectedSignups() async {
    final res = await _send('GET', '/signups/rejected');
    return ((res.data as Map<String, dynamic>)['applicants'] as List? ?? const [])
        .map((e) => PendingApplicant.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /signups/approved — recently-approved (last 7 days) students,
  /// newest first. Feeds the Approved tab so the manager can grab the
  /// phone number to call straight after approving.
  Future<List<PendingApplicant>> listApprovedSignups() async {
    final res = await _send('GET', '/signups/approved');
    return ((res.data as Map<String, dynamic>)['applicants'] as List? ?? const [])
        .map((e) => PendingApplicant.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /signups/{id}/restore — flip a rejected (disabled-no-bookings)
  /// student back to pending_approval so they show up in the review queue
  /// again. Used by the Rejected tab's "Restore" action.
  Future<void> restoreSignup(String userId) async {
    await _send('POST', '/signups/$userId/restore');
  }

  // ----- Admin: students list -----

  Future<List<StudentRow>> listStudents({String? q}) async {
    final res = await _send('GET', '/students',
        query: (q == null || q.isEmpty) ? null : {'q': q});
    return ((res.data as Map<String, dynamic>)['students'] as List? ?? const [])
        .map((e) => StudentRow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /sessions/{id}/waitlist — student joins the waitlist for a
  /// full session. Returns 409 with `session_not_full` if there's still
  /// capacity (the caller should book instead).
  Future<void> joinSessionWaitlist(String sessionId) async {
    await _send('POST', '/sessions/$sessionId/waitlist');
  }

  Future<void> leaveSessionWaitlist(String sessionId) async {
    await _send('DELETE', '/sessions/$sessionId/waitlist');
  }

  /// GET /me/waitlist — entries owned by the calling student.
  Future<List<Map<String, dynamic>>> listMyWaitlist() async {
    final res = await _send('GET', '/me/waitlist');
    return ((res.data as Map<String, dynamic>)['entries'] as List? ??
            const [])
        .cast<Map<String, dynamic>>();
  }

  /// GET /sessions/{id}/waitlist — staff enumeration of the queue for
  /// one session. Returns rows + count for the manager's session detail.
  Future<({List<Map<String, dynamic>> entries, int count})>
      listSessionWaitlist(String sessionId) async {
    final res = await _send('GET', '/sessions/$sessionId/waitlist');
    final m = res.data as Map<String, dynamic>;
    return (
      entries: ((m['entries'] as List?) ?? const [])
          .cast<Map<String, dynamic>>(),
      count: (m['count'] as num?)?.toInt() ?? 0,
    );
  }

  /// GET /followups — school-wide open follow-ups + counts in one call.
  Future<({List<Map<String, dynamic>> followups, int open, int overdue})>
      listOpenFollowups() async {
    final res = await _send('GET', '/followups');
    final m = res.data as Map<String, dynamic>;
    final counts = (m['counts'] as Map<String, dynamic>?) ?? const {};
    return (
      followups: ((m['followups'] as List?) ?? const [])
          .cast<Map<String, dynamic>>(),
      open: (counts['open'] as num?)?.toInt() ?? 0,
      overdue: (counts['overdue'] as num?)?.toInt() ?? 0,
    );
  }

  /// GET /incidents/{id}/followups — staff list of follow-up actions
  /// spawned for an incident.
  Future<List<Map<String, dynamic>>> listIncidentFollowups(String incidentId) async {
    final res = await _send('GET', '/incidents/$incidentId/followups');
    return ((res.data as Map<String, dynamic>)['followups'] as List? ??
            const [])
        .cast<Map<String, dynamic>>();
  }

  Future<void> completeFollowup({
    required String followupId,
    String notes = '',
  }) async {
    await _send('POST', '/followups/$followupId/done',
        data: notes.isEmpty ? null : {'notes': notes});
  }

  Future<void> reopenFollowup(String followupId) async {
    await _send('POST', '/followups/$followupId/reopen');
  }

  /// POST /sessions — admin creates one ad-hoc session. instructorIds
  /// is 0..N; an empty list flags the session as "needs instructor".
  /// Server-side ratio violations come back as soft warnings — the
  /// session is created regardless.
  Future<({String id, List<String> warnings})> createSession({
    required String courseTypeId,
    required String locationId,
    required DateTime startsAt,
    required DateTime endsAt,
    required int capacity,
    List<String> instructorIds = const [],
    String notes = '',
  }) async {
    final res = await _send('POST', '/sessions', data: {
      'courseTypeId': courseTypeId,
      'locationId': locationId,
      'startsAt': startsAt.toUtc().toIso8601String(),
      'endsAt': endsAt.toUtc().toIso8601String(),
      'capacity': capacity,
      'instructorIds': instructorIds,
      if (notes.isNotEmpty) 'notes': notes,
    });
    final m = res.data as Map<String, dynamic>;
    final warnings = ((m['warnings'] as List?) ?? const [])
        .map((w) => ((w as Map)['message'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toList();
    return (id: (m['id'] ?? '') as String, warnings: warnings);
  }

  /// PATCH /sessions/{id} — move a session to a new (startsAt, endsAt)
  /// window. Backs the master-calendar drag-to-move interaction.
  Future<void> updateSessionTime({
    required String sessionId,
    required DateTime startsAt,
    required DateTime endsAt,
  }) async {
    await _send('PATCH', '/sessions/$sessionId', data: {
      'startsAt': startsAt.toUtc().toIso8601String(),
      'endsAt': endsAt.toUtc().toIso8601String(),
    });
  }

  /// PATCH /sessions/{id} with whichever subset of fields the edit
  /// sheet collected. Nil/empty fields are omitted so the server only
  /// touches what the manager actually changed. Course type, location
  /// and instructor assignment live on their own endpoints.
  Future<void> updateSession({
    required String sessionId,
    DateTime? startsAt,
    DateTime? endsAt,
    int? capacity,
  }) async {
    if (startsAt == null && endsAt == null && capacity == null) return;
    await _send('PATCH', '/sessions/$sessionId', data: {
      if (startsAt != null) 'startsAt': startsAt.toUtc().toIso8601String(),
      if (endsAt != null) 'endsAt': endsAt.toUtc().toIso8601String(),
      if (capacity != null) 'capacity': capacity,
    });
  }

  /// PUT /sessions/{id}/instructors — replace the instructor
  /// assignment. Empty list clears the session.
  Future<void> setSessionInstructors({
    required String sessionId,
    required List<String> instructorIds,
  }) async {
    await _send('PUT', '/sessions/$sessionId/instructors', data: {
      'instructorIds': instructorIds,
    });
  }

  /// POST /sessions/cancel-batch — manager bulk-cancels N sessions.
  /// Each session is its own tx; results return per-session outcomes.
  Future<({int sessionsCancelled, int bookingsCancelled})> cancelSessionsBatch({
    required List<String> sessionIds,
    String reason = '',
  }) async {
    final res = await _send('POST', '/sessions/cancel-batch', data: {
      'sessionIds': sessionIds,
      if (reason.isNotEmpty) 'reason': reason,
    });
    final m = res.data as Map<String, dynamic>;
    return (
      sessionsCancelled: (m['sessionsCancelled'] as num?)?.toInt() ?? 0,
      bookingsCancelled: (m['bookingsCancelled'] as num?)?.toInt() ?? 0,
    );
  }

  /// GET /closures — admin/owner list of school-wide closed dates.
  Future<List<Map<String, dynamic>>> listClosures() async {
    final res = await _send('GET', '/closures');
    return ((res.data as Map<String, dynamic>)['closures'] as List? ??
            const [])
        .cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createClosure({
    required String fromDate,
    String toDate = '',
    required String label,
    String reason = '',
  }) async {
    final res = await _send('POST', '/closures', data: {
      'fromDate': fromDate,
      if (toDate.isNotEmpty) 'toDate': toDate,
      'label': label,
      if (reason.isNotEmpty) 'reason': reason,
    });
    return res.data as Map<String, dynamic>;
  }

  Future<void> deleteClosure(String id) async {
    await _send('DELETE', '/closures/$id');
  }

  /// GET /session-templates — list admin templates.
  Future<List<SessionTemplate>> listSessionTemplates() async {
    final res = await _send('GET', '/session-templates');
    return ((res.data as Map<String, dynamic>)['templates'] as List? ??
            const [])
        .map((e) => SessionTemplate.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<SessionTemplate> createSessionTemplate({
    required String courseTypeId,
    String instructorId = '',
    required String locationId,
    required int weekday,
    required String startsAtTime,
    required int durationMinutes,
    required int capacity,
    String startsOn = '',
    String endsOn = '',
    String notes = '',
  }) async {
    final res = await _send('POST', '/session-templates', data: {
      'courseTypeId': courseTypeId,
      if (instructorId.isNotEmpty) 'instructorId': instructorId,
      'locationId': locationId,
      'weekday': weekday,
      'startsAtTime': startsAtTime,
      'durationMinutes': durationMinutes,
      'capacity': capacity,
      if (startsOn.isNotEmpty) 'startsOn': startsOn,
      if (endsOn.isNotEmpty) 'endsOn': endsOn,
      if (notes.isNotEmpty) 'notes': notes,
    });
    return SessionTemplate.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteSessionTemplate(String id) async {
    await _send('DELETE', '/session-templates/$id');
  }

  /// POST /session-templates/materialise — generate sessions for the
  /// next N weeks across all templates. Returns ({created, id}); id is
  /// empty when nothing new was generated (idempotent re-run).
  Future<({int created, String id})> materialiseTemplates({int weeks = 4}) async {
    final res = await _send('POST', '/session-templates/materialise',
        query: {'weeks': weeks.toString()});
    final m = res.data as Map<String, dynamic>;
    return (
      created: (m['created'] as num?)?.toInt() ?? 0,
      id: (m['materialisationId'] ?? '') as String,
    );
  }

  /// POST /session-templates/{id}/materialise — same as above but
  /// scoped to one template.
  Future<({int created, String id})> materialiseOneTemplate(
      String templateId, {int weeks = 4}) async {
    final res = await _send('POST', '/session-templates/$templateId/materialise',
        query: {'weeks': weeks.toString()});
    final m = res.data as Map<String, dynamic>;
    return (
      created: (m['created'] as num?)?.toInt() ?? 0,
      id: (m['materialisationId'] ?? '') as String,
    );
  }

  /// GET /session-templates/materialisations — recent passes.
  Future<List<Map<String, dynamic>>> listMaterialisations() async {
    final res = await _send('GET', '/session-templates/materialisations');
    return ((res.data as Map<String, dynamic>)['materialisations'] as List? ??
            const [])
        .cast<Map<String, dynamic>>();
  }

  /// POST /session-templates/materialisations/{id}/undo — delete every
  /// session this pass generated. Throws ApiException(code=has_bookings)
  /// when one or more sessions already have student bookings.
  Future<int> undoMaterialisation(String id) async {
    final res = await _send('POST',
        '/session-templates/materialisations/$id/undo');
    return ((res.data as Map<String, dynamic>)['deleted'] as num?)?.toInt() ??
        0;
  }

  /// GET /session-templates/{id}/preview — count of NEW sessions the
  /// next materialise pass would create for this template.
  Future<int> previewSessionTemplate(String id, {int weeks = 4}) async {
    final res = await _send('GET', '/session-templates/$id/preview',
        query: {'weeks': weeks.toString()});
    return ((res.data as Map<String, dynamic>)['newSessions'] as num?)
            ?.toInt() ??
        0;
  }

  /// GET /revenue — admin-only consolidated finance overview.
  Future<RevenueReport> getRevenue({int months = 12}) async {
    final res = await _send('GET', '/revenue',
        query: {'months': months.toString()});
    return RevenueReport.fromJson(res.data as Map<String, dynamic>);
  }

  /// GET /compliance — admin-only consolidated bike/instructor/school
  /// expiry view, with severity buckets precomputed server-side.
  Future<ComplianceReport> getCompliance() async {
    final res = await _send('GET', '/compliance');
    return ComplianceReport.fromJson(res.data as Map<String, dynamic>);
  }

  /// PUT /school/insurance — set or clear.
  Future<void> setInsurance({required String expiresOn}) async {
    await _send('PUT', '/school/insurance', data: {'expiresOn': expiresOn});
  }

  /// GET /audit — admin-only paginated mutation history.
  /// Filters are passed as query params; the backend caps `limit` at 500.
  Future<AuditPage> listAudit({
    String? actor,
    String? entity,
    String? targetId,
    DateTime? from,
    DateTime? to,
    int limit = 100,
    int offset = 0,
  }) async {
    final params = <String, dynamic>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    if (actor != null && actor.isNotEmpty) params['actor'] = actor;
    if (entity != null && entity.isNotEmpty) params['entity'] = entity;
    if (targetId != null && targetId.isNotEmpty) params['targetId'] = targetId;
    if (from != null) params['from'] = from.toUtc().toIso8601String();
    if (to != null) params['to'] = to.toUtc().toIso8601String();
    final res = await _send('GET', '/audit', query: params);
    return AuditPage.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /students — admin-only manual create. Backend mints the
  /// Firebase identity, writes users + student_profiles, and returns a
  /// row shaped like one entry of GET /students.
  Future<StudentRow> createStudent({
    required String name,
    required String email,
    required String password,
    String phone = '',
  }) async {
    final res = await _send('POST', '/students', data: {
      'name': name,
      'email': email,
      'phone': phone,
      'password': password,
    });
    return StudentRow.fromJson(res.data as Map<String, dynamic>);
  }

  // ----- Admin: student detail aggregate -----

  /// /students/{id} — the manager-only big view. Returns a raw map; the
  /// detail screen rebuilds typed views from sub-trees.
  Future<Map<String, dynamic>> studentDetail(String studentId) async {
    final res = await _send('GET', '/students/$studentId');
    return res.data as Map<String, dynamic>;
  }

  /// POST /students/{id}/charges — admin records a new charge.
  Future<void> addStudentCharge({
    required String studentId,
    required int amountPence,
    required String description,
    String? bookingId,
  }) async {
    await _send('POST', '/students/$studentId/charges', data: {
      'amountPence': amountPence,
      'description': description,
      if (bookingId != null && bookingId.isNotEmpty) 'bookingId': bookingId,
    });
  }

  /// POST /students/{id}/notes — staff-only safety flag or progress note.
  Future<void> addStudentNote({
    required String studentId,
    required String kind, // 'safety_flag' | 'progress_note'
    required String body,
  }) async {
    await _send('POST', '/students/$studentId/notes',
        data: {'kind': kind, 'body': body});
  }

  /// DELETE /notes/{noteId} — deactivates (kept for audit).
  Future<void> deactivateStudentNote(String noteId) async {
    await _send('DELETE', '/notes/$noteId');
  }

  // ----- Admin: fleet -----

  Future<List<FleetBike>> listFleet() async {
    final res = await _send('GET', '/bikes');
    return ((res.data as Map<String, dynamic>)['bikes'] as List? ?? const [])
        .map((e) => FleetBike.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /bikes — create a new bike. Backend defaults status to 'ready'
  /// and sets current_location_id = home_location_id.
  Future<FleetBike> createBike({
    required String nickname,
    required String make,
    required String model,
    required String registration,
    required String category, // A1 | A2 | A
    required String transmission, // manual | auto
    required int engineCc,
    required String homeLocationId,
  }) async {
    final res = await _send('POST', '/bikes', data: {
      'nickname': nickname,
      'make': make,
      'model': model,
      'registration': registration,
      'category': category,
      'transmission': transmission,
      'engineCc': engineCc,
      'homeLocationId': homeLocationId,
    });
    return FleetBike.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /bikes/{id}/offline — opens a bike-down disruption. Returns the
  /// affected-bookings payload so the caller can show what's impacted.
  Future<Map<String, dynamic>> takeBikeOffline({
    required String bikeId,
    required String reason, // 'mechanic' | 'damaged' | 'broken' | 'off_road' | 'other'
    String? notes,
  }) async {
    final res = await _send('POST', '/bikes/$bikeId/offline', data: {
      'reason': reason,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    });
    return res.data as Map<String, dynamic>;
  }

  /// POST /bikes/{id}/restore — back to 'ready', clears open-ended
  /// unavailability windows.
  Future<void> restoreBike(String bikeId) async {
    await _send('POST', '/bikes/$bikeId/restore');
  }

  /// POST /incidents — staff log an incident on a bike/student/booking.
  /// Setting `takeBikeOffline: true` rolls the bike-offline + disruption
  /// flow into the same request so the instructor can report a crash and
  /// pull the bike from service in one tap.
  Future<Map<String, dynamic>> logIncident({
    String? bikeId,
    String? studentId,
    String? bookingId,
    DateTime? occurredAt,
    required String description,
    bool takeBikeOffline = false,
    String? offlineReason,
  }) async {
    final res = await _send('POST', '/incidents', data: {
      if (bikeId != null && bikeId.isNotEmpty) 'bikeId': bikeId,
      if (studentId != null && studentId.isNotEmpty) 'studentId': studentId,
      if (bookingId != null && bookingId.isNotEmpty) 'bookingId': bookingId,
      if (occurredAt != null) 'occurredAt': occurredAt.toUtc().toIso8601String(),
      'description': description,
      'takeBikeOffline': takeBikeOffline,
      if (offlineReason != null && offlineReason.isNotEmpty)
        'offlineReason': offlineReason,
    });
    return res.data as Map<String, dynamic>;
  }

  /// POST /bikes/{id}/move — update a bike's current_location_id. Used by
  /// the logistics screen after staff physically move the bike.
  Future<void> moveBike({required String bikeId, required String locationId}) async {
    await _send('POST', '/bikes/$bikeId/move', data: {'locationId': locationId});
  }

  // ----- Admin: disruptions -----

  /// GET /disruptions?status=open|all — list with affected bookings + live
  /// swap candidates for pending rows.
  Future<List<Map<String, dynamic>>> listDisruptions({bool openOnly = true}) async {
    final res = await _send('GET', '/disruptions',
        query: {if (!openOnly) 'status': 'all'});
    return ((res.data as Map<String, dynamic>)['disruptions'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
  }

  /// POST /disruptions/{id}/bookings/{bookingId}/resolve — apply a swap
  /// (resolution=swapped, requires newBikeId) or cancel-with-approval.
  Future<void> resolveDisruptionBooking({
    required String disruptionId,
    required String bookingId,
    required String resolution, // 'swapped' | 'cancel_with_approval'
    String? newBikeId,
    String? notes,
  }) async {
    await _send('POST', '/disruptions/$disruptionId/bookings/$bookingId/resolve',
        data: {
          'resolution': resolution,
          if (newBikeId != null && newBikeId.isNotEmpty) 'newBikeId': newBikeId,
          if (notes != null && notes.isNotEmpty) 'notes': notes,
        });
  }

  /// POST /disruptions/dismiss-past — bulk cancel-with-approval for
  /// every pending affected-booking whose session has already ended.
  /// Returns the count of rows processed.
  Future<int> dismissPastDisruptions() async {
    final res = await _send('POST', '/disruptions/dismiss-past');
    return ((res.data as Map<String, dynamic>)['cancelled'] as num?)?.toInt() ?? 0;
  }

  // ----- Admin: logistics -----

  /// GET /logistics?date=YYYY-MM-DD — derived view of bike moves needed.
  Future<Map<String, dynamic>> logistics({DateTime? date}) async {
    final params = <String, dynamic>{};
    if (date != null) {
      params['date'] =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    }
    final res = await _send('GET', '/logistics', query: params.isEmpty ? null : params);
    return res.data as Map<String, dynamic>;
  }

  // ----- Admin: instructors -----

  Future<List<InstructorRow>> listInstructors() async {
    final res = await _send('GET', '/instructors');
    return ((res.data as Map<String, dynamic>)['instructors'] as List? ?? const [])
        .map((e) => InstructorRow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<InstructorRow> inviteInstructor({
    required String name,
    required String email,
    required String phone,
    required String password,
    required String homeLocationId,
    required List<Accreditation> accreditations,
  }) async {
    final res = await _send('POST', '/instructors', data: {
      'name': name,
      'email': email,
      'phone': phone,
      'password': password,
      if (homeLocationId.isNotEmpty) 'homeLocationId': homeLocationId,
      'accreditations': accreditations.map((a) => a.toJson()).toList(),
    });
    return InstructorRow.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> setInstructorAccreditations({
    required String instructorId,
    required List<Accreditation> accreditations,
  }) async {
    await _send('PUT', '/instructors/$instructorId/accreditations', data: {
      'accreditations': accreditations.map((a) => a.toJson()).toList(),
    });
  }

  // ----- Admin: instructor pay -----

  Future<List<InstructorPayRow>> listInstructorPayOutstanding() async {
    final res = await _send('GET', '/instructor-pay/outstanding');
    return ((res.data as Map<String, dynamic>)['instructors'] as List? ?? const [])
        .map((e) => InstructorPayRow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<PayModel?> getInstructorPayModel(String instructorId) async {
    try {
      final res = await _send('GET', '/instructors/$instructorId/pay-model');
      return PayModel.fromJson(res.data as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> setInstructorPayModel({
    required String instructorId,
    required String payBasis,
    required int rateValue,
  }) async {
    await _send('PUT', '/instructors/$instructorId/pay-model',
        data: {'payBasis': payBasis, 'rateValue': rateValue});
  }

  Future<void> recordInstructorEarning({
    required String instructorId,
    required int amountPence,
    required String basis,
    String? sessionId,
    String? notes,
  }) async {
    await _send('POST', '/instructors/$instructorId/earnings', data: {
      'amountPence': amountPence,
      'basis': basis,
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    });
  }

  Future<void> recordInstructorPayment({
    required String instructorId,
    required int amountPence,
    required String method,
    DateTime? paidAt,
    String? notes,
  }) async {
    await _send('POST', '/instructors/$instructorId/payments', data: {
      'amountPence': amountPence,
      'method': method,
      if (paidAt != null) 'paidAt': paidAt.toUtc().toIso8601String(),
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    });
  }

  // ----- Admin: course types (lightweight list for pickers) -----

  Future<List<CourseTypeLite>> listCourseTypes() async {
    final res = await _send('GET', '/course-types');
    return ((res.data as Map<String, dynamic>)['courseTypes'] as List? ?? const [])
        .map((e) => CourseTypeLite.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ----- Admin: school settings update -----

  /// PATCH /school — partial update of school settings. Fields not supplied
  /// are left unchanged.
  Future<void> updateSchoolSettings({
    String? name,
    String? testBodyLabel,
    String? onboardingMode,
    bool? instructorsCanRecordPayments,
    int? cancelCutoffHours,
    int? travelBufferMinutes,
    int? crossSiteNoticeHours,
    int? motWarnDays,
    int? motUrgentDays,
    int? taxWarnDays,
    int? taxUrgentDays,
    int? accreditationWarnDays,
    int? accreditationUrgentDays,
    int? insuranceWarnDays,
    int? insuranceUrgentDays,
  }) async {
    await _send('PATCH', '/school', data: {
      if (name != null) 'name': name,
      if (testBodyLabel != null) 'testBodyLabel': testBodyLabel,
      if (onboardingMode != null) 'onboardingMode': onboardingMode,
      if (instructorsCanRecordPayments != null) 'instructorsCanRecordPayments': instructorsCanRecordPayments,
      if (cancelCutoffHours != null) 'cancelCutoffHours': cancelCutoffHours,
      if (travelBufferMinutes != null) 'travelBufferMinutes': travelBufferMinutes,
      if (crossSiteNoticeHours != null) 'crossSiteNoticeHours': crossSiteNoticeHours,
      if (motWarnDays != null) 'motWarnDays': motWarnDays,
      if (motUrgentDays != null) 'motUrgentDays': motUrgentDays,
      if (taxWarnDays != null) 'taxWarnDays': taxWarnDays,
      if (taxUrgentDays != null) 'taxUrgentDays': taxUrgentDays,
      if (accreditationWarnDays != null) 'accreditationWarnDays': accreditationWarnDays,
      if (accreditationUrgentDays != null) 'accreditationUrgentDays': accreditationUrgentDays,
      if (insuranceWarnDays != null) 'insuranceWarnDays': insuranceWarnDays,
      if (insuranceUrgentDays != null) 'insuranceUrgentDays': insuranceUrgentDays,
    });
  }

  // ----- Admin: locations CRUD -----

  Future<LocationLite> createLocation({required String name, String address = ''}) async {
    final res = await _send('POST', '/locations', data: {'name': name, 'address': address});
    return LocationLite.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> updateLocation({required String id, required String name, String address = ''}) async {
    await _send('PUT', '/locations/$id', data: {'name': name, 'address': address});
  }

  /// PUT /bikes/{id} — partial update. Pass empty strings for the MOT
  /// / tax dates to clear them; null to leave them unchanged.
  Future<void> updateBikeState({
    required String id,
    required String nickname,
    required String make,
    required String model,
    required String registration,
    required int engineCc,
    String homeLocationId = '',
    String? motExpiresOn,
    String? taxExpiresOn,
  }) async {
    await _send('PUT', '/bikes/$id', data: {
      'nickname': nickname,
      'make': make,
      'model': model,
      'registration': registration,
      'engineCc': engineCc,
      if (homeLocationId.isNotEmpty) 'homeLocationId': homeLocationId,
      if (motExpiresOn != null) 'motExpiresOn': motExpiresOn,
      if (taxExpiresOn != null) 'taxExpiresOn': taxExpiresOn,
    });
  }

  /// POST /bikes/{id}/mileage — record a new reading.
  Future<void> recordBikeMileage({
    required String id,
    required int miles,
    String source = 'manual',
  }) async {
    await _send('POST', '/bikes/$id/mileage',
        data: {'miles': miles, 'source': source});
  }

  // ----- Bike maintenance log -----

  /// GET /bikes/{id}/expenses — maintenance history + YTD total.
  Future<BikeExpensesPayload> listBikeExpenses(String bikeId) async {
    final res = await _send('GET', '/bikes/$bikeId/expenses');
    return BikeExpensesPayload.fromJson(res.data as Map<String, dynamic>);
  }

  /// POST /bikes/{id}/expenses (multipart) — record a maintenance line.
  /// Returns the created expense.
  Future<BikeExpense> recordBikeExpense({
    required String bikeId,
    required String category, // parts | labour | mot | tax | service | other
    required int amountPence,
    required String receiptPath,
    String? vendor,
    String? notes,
    DateTime? occurredAt,
  }) async {
    final form = FormData.fromMap({
      'category': category,
      'amountPence': amountPence.toString(),
      if (occurredAt != null)
        'occurredAt':
            '${occurredAt.year.toString().padLeft(4, '0')}-${occurredAt.month.toString().padLeft(2, '0')}-${occurredAt.day.toString().padLeft(2, '0')}',
      if (vendor != null && vendor.isNotEmpty) 'vendor': vendor,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      'receipt': await MultipartFile.fromFile(receiptPath, filename: 'receipt.jpg'),
    });
    final res = await _dio.post<dynamic>('/bikes/$bikeId/expenses',
        data: form,
        options: Options(
          contentType: 'multipart/form-data',
          validateStatus: (s) => s != null && s < 500,
        ));
    if ((res.statusCode ?? 0) >= 400) {
      final body = res.data;
      if (body is Map<String, dynamic>) {
        throw ApiException(res.statusCode!,
            body['error']?.toString() ?? 'unknown',
            body['message']?.toString() ?? 'Could not record the expense.');
      }
      throw ApiException(res.statusCode ?? 0, 'unknown', 'Could not record the expense.');
    }
    final wrap = res.data as Map<String, dynamic>;
    return BikeExpense.fromJson(wrap['expense'] as Map<String, dynamic>);
  }

  /// URL for streaming the full receipt image — drop into
  /// CachedNetworkImage with the auth header.
  String bikeExpenseReceiptUrl(String id) =>
      '${_dio.options.baseUrl}/bike-expenses/$id/receipt';

  /// DELETE /bike-expenses/{id} — remove a maintenance record.
  Future<void> deleteBikeExpense(String id) async {
    await _send('DELETE', '/bike-expenses/$id');
  }

  Future<void> deleteLocation(String id) async {
    await _send('DELETE', '/locations/$id');
  }

  // ----- Admin: travel-time matrix -----

  Future<List<TravelTime>> listTravelTimes() async {
    final res = await _send('GET', '/travel-times');
    return ((res.data as Map<String, dynamic>)['travelTimes'] as List? ?? const [])
        .map((e) => TravelTime.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> setTravelTime({
    required String fromLocationId,
    required String toLocationId,
    required int minutes,
  }) async {
    await _send('PUT', '/travel-times', data: {
      'fromLocationId': fromLocationId,
      'toLocationId': toLocationId,
      'minutes': minutes,
    });
  }

  Future<void> deleteTravelTime({required String fromLocationId, required String toLocationId}) async {
    await _send('DELETE', '/travel-times/$fromLocationId/$toLocationId');
  }

  // ----- Admin: course types CRUD + competencies -----

  Future<List<CourseTypeFull>> listCourseTypesFull() async {
    final res = await _send('GET', '/course-types');
    return ((res.data as Map<String, dynamic>)['courseTypes'] as List? ?? const [])
        .map((e) => CourseTypeFull.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<CourseTypeFull> createCourseType({
    required String code,
    required String name,
    required String region,
    required String requiredBikeCategory,
    required int durationMinutes,
    required int maxRatio,
    required int pricePence,
    required bool nonTeaching,
    int cancellationCutoffHours = 0,
    String accentColour = '',
    List<String> prerequisites = const [],
  }) async {
    final res = await _send('POST', '/course-types', data: {
      'code': code,
      'name': name,
      'region': region,
      'requiredBikeCategory': requiredBikeCategory,
      'durationMinutes': durationMinutes,
      'maxRatio': maxRatio,
      'pricePence': pricePence,
      'nonTeaching': nonTeaching,
      'cancellationCutoffHours': cancellationCutoffHours,
      'accentColour': accentColour,
      'prerequisites': prerequisites,
    });
    return CourseTypeFull.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> updateCourseType({
    required String id,
    required String code,
    required String name,
    required String region,
    required String requiredBikeCategory,
    required int durationMinutes,
    required int maxRatio,
    required int pricePence,
    required bool nonTeaching,
    int cancellationCutoffHours = 0,
    String accentColour = '',
    List<String> prerequisites = const [],
  }) async {
    await _send('PUT', '/course-types/$id', data: {
      'code': code,
      'name': name,
      'region': region,
      'requiredBikeCategory': requiredBikeCategory,
      'durationMinutes': durationMinutes,
      'maxRatio': maxRatio,
      'pricePence': pricePence,
      'nonTeaching': nonTeaching,
      'cancellationCutoffHours': cancellationCutoffHours,
      'accentColour': accentColour,
      'prerequisites': prerequisites,
    });
  }

  Future<void> deleteCourseType(String id) async {
    await _send('DELETE', '/course-types/$id');
  }

  Future<List<Competency>> listCompetencies(String courseTypeId) async {
    final res = await _send('GET', '/course-types/$courseTypeId/competencies');
    return ((res.data as Map<String, dynamic>)['competencies'] as List? ?? const [])
        .map((e) => Competency.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Competency> createCompetency({
    required String courseTypeId,
    required String label,
    int sortOrder = 0,
  }) async {
    final res = await _send('POST', '/course-types/$courseTypeId/competencies',
        data: {'label': label, 'sortOrder': sortOrder});
    return Competency.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteCompetency(String id) async {
    await _send('DELETE', '/competencies/$id');
  }

  // ----- Reimbursements (instructor expenses) -----

  /// GET /expense-categories — the per-school category list driving the
  /// chip selector and the admin's "Manage types" modal.
  Future<List<ExpenseCategory>> listExpenseCategories({bool activeOnly = false}) async {
    final res = await _send('GET', '/expense-categories',
        query: {if (activeOnly) 'activeOnly': '1'});
    return ((res.data as Map<String, dynamic>)['categories'] as List? ?? const [])
        .map((e) => ExpenseCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// PUT /expense-categories — owner/admin replaces the full list (idempotent).
  Future<List<ExpenseCategory>> upsertExpenseCategories(
      List<ExpenseCategory> cats) async {
    final res = await _send('PUT', '/expense-categories',
        data: {'categories': cats.map((c) => c.toJson()).toList()});
    return ((res.data as Map<String, dynamic>)['categories'] as List? ?? const [])
        .map((e) => ExpenseCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /me/expenses — multipart submission. Returns the created expense.
  Future<Expense> submitExpense({
    required String categoryId,
    required int amountPence,
    required DateTime occurredAt,
    required Uint8List receiptBytes,
    required String receiptFilename,
    String? where,
    String? notes,
  }) async {
    final form = FormData.fromMap({
      'categoryId': categoryId,
      'amountPence': amountPence.toString(),
      'occurredAt': occurredAt.toUtc().toIso8601String(),
      if (where != null && where.isNotEmpty) 'where': where,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      // Bytes (not File) so this works on web — `MultipartFile.fromFile`
      // would assert on `kIsWeb`.
      'receipt': MultipartFile.fromBytes(receiptBytes, filename: receiptFilename),
    });
    // Don't use _send: it forces application/json and we need multipart.
    final res = await _dio.post<dynamic>('/me/expenses',
        data: form,
        options: Options(
          contentType: 'multipart/form-data',
          validateStatus: (s) => s != null && s < 500,
        ));
    if ((res.statusCode ?? 0) >= 400) {
      final body = res.data;
      if (body is Map<String, dynamic>) {
        throw ApiException(res.statusCode!,
            body['error']?.toString() ?? 'unknown',
            body['message']?.toString() ?? 'Something went wrong.');
      }
      throw ApiException(res.statusCode ?? 0, 'unknown', 'Something went wrong.');
    }
    return Expense.fromJson((res.data as Map<String, dynamic>)['expense']);
  }

  /// GET /me/expenses?status= — instructor self-serve list.
  Future<MyExpensesPayload> listMyExpenses({String? status}) async {
    final res = await _send('GET', '/me/expenses',
        query: {if (status != null && status.isNotEmpty) 'status': status});
    return MyExpensesPayload.fromJson(res.data as Map<String, dynamic>);
  }

  /// DELETE /me/expenses/{id} — instructor withdraws while pending.
  Future<void> withdrawExpense(String id) async {
    await _send('DELETE', '/me/expenses/$id');
  }

  /// GET /expenses?status= — admin review queue.
  Future<ExpensesQueuePayload> listExpensesForReview({String? status}) async {
    final res = await _send('GET', '/expenses',
        query: {if (status != null && status.isNotEmpty) 'status': status});
    return ExpensesQueuePayload.fromJson(res.data as Map<String, dynamic>);
  }

  /// GET /expenses/{id} — single expense.
  Future<Expense> getExpense(String id) async {
    final res = await _send('GET', '/expenses/$id');
    return Expense.fromJson((res.data as Map<String, dynamic>)['expense']);
  }

  /// URL for the auth-gated receipt stream. Use in Image.network — the Dio
  /// auth interceptor doesn't fire for raw network image requests, so we
  /// pass the bearer token as a header via Image.network's `headers:`.
  String receiptUrl(String id) => '${_dio.options.baseUrl}/expenses/$id/receipt';

  Future<Expense> approveExpense(String id, {String? reviewerNote}) async {
    final res = await _send('POST', '/expenses/$id/approve',
        data: {if (reviewerNote != null && reviewerNote.isNotEmpty) 'reviewerNote': reviewerNote});
    return Expense.fromJson((res.data as Map<String, dynamic>)['expense']);
  }

  Future<Expense> rejectExpense(String id, {required String reviewerNote}) async {
    final res = await _send('POST', '/expenses/$id/reject',
        data: {'reviewerNote': reviewerNote});
    return Expense.fromJson((res.data as Map<String, dynamic>)['expense']);
  }

  Future<Expense> reimburseExpense(String id, {String paidMethod = 'bank'}) async {
    final res = await _send('POST', '/expenses/$id/reimburse',
        data: {'paidMethod': paidMethod});
    return Expense.fromJson((res.data as Map<String, dynamic>)['expense']);
  }

  /// Last-known bearer token, for callers that need it synchronously
  /// (e.g. `Image.network` headers). Populated by the request
  /// interceptor on every call, so any UI mounted after at least one
  /// API request has fired sees a fresh value.
  String? currentToken() => _cachedToken;
}
