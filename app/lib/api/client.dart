// Dio HTTP client with a bearer-token interceptor.
//
// The token is supplied via a getter so it can change at runtime (login /
// logout) without rebuilding the client. Errors from the Go server come
// back as {"error": code, "message": text} — the response interceptor
// unwraps them into ApiException so callers branch on a stable code.

import 'package:dio/dio.dart';

import 'models.dart';

class ApiClient {
  final Dio _dio;
  String? Function() _tokenSupplier;

  ApiClient({required String baseUrl, required String? Function() tokenSupplier})
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
      onRequest: (options, handler) {
        final t = _tokenSupplier();
        if (t != null && t.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $t';
        }
        handler.next(options);
      },
    ));
  }

  /// Replace the token supplier — used after login completes.
  void setTokenSupplier(String? Function() s) {
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

  Future<LoginResult> login(String email, String password) async {
    final res = await _send('POST', '/auth/login',
        data: {'email': email, 'password': password});
    return LoginResult.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> logout() async {
    await _send('POST', '/auth/logout');
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
  }) async {
    final res = await _send('GET', '/calendar', query: {
      'from': from.toUtc().toIso8601String(),
      'to': to.toUtc().toIso8601String(),
      if (instructorId != null && instructorId.isNotEmpty) 'instructorId': instructorId,
      if (locationId != null && locationId.isNotEmpty) 'locationId': locationId,
      if (courseTypeId != null && courseTypeId.isNotEmpty) 'courseTypeId': courseTypeId,
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

  // ----- Admin: students list -----

  Future<List<StudentRow>> listStudents({String? q}) async {
    final res = await _send('GET', '/students',
        query: (q == null || q.isEmpty) ? null : {'q': q});
    return ((res.data as Map<String, dynamic>)['students'] as List? ?? const [])
        .map((e) => StudentRow.fromJson(e as Map<String, dynamic>))
        .toList();
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
    required List<String> qualifiedCourseIds,
  }) async {
    final res = await _send('POST', '/instructors', data: {
      'name': name,
      'email': email,
      'phone': phone,
      'password': password,
      if (homeLocationId.isNotEmpty) 'homeLocationId': homeLocationId,
      'qualifiedCourseIds': qualifiedCourseIds,
    });
    return InstructorRow.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> setInstructorQualifications({
    required String instructorId,
    required List<String> courseTypeIds,
  }) async {
    await _send('PUT', '/instructors/$instructorId/qualifications', data: {
      'courseTypeIds': courseTypeIds,
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
    String? onboardingMode,
    bool? instructorsCanRecordPayments,
    int? cancelCutoffHours,
    int? travelBufferMinutes,
  }) async {
    await _send('PATCH', '/school', data: {
      if (onboardingMode != null) 'onboardingMode': onboardingMode,
      if (instructorsCanRecordPayments != null) 'instructorsCanRecordPayments': instructorsCanRecordPayments,
      if (cancelCutoffHours != null) 'cancelCutoffHours': cancelCutoffHours,
      if (travelBufferMinutes != null) 'travelBufferMinutes': travelBufferMinutes,
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
    required String receiptPath,
    String? where,
    String? notes,
  }) async {
    final form = FormData.fromMap({
      'categoryId': categoryId,
      'amountPence': amountPence.toString(),
      'occurredAt': occurredAt.toUtc().toIso8601String(),
      if (where != null && where.isNotEmpty) 'where': where,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      'receipt': await MultipartFile.fromFile(receiptPath, filename: 'receipt.jpg'),
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

  /// Bearer token getter so screens that load the receipt via `Image.network`
  /// can pass it as an Authorization header.
  String? currentToken() => _tokenSupplier();
}
