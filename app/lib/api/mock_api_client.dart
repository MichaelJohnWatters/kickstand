// Mock ApiClient backed by static JSON assets dumped from the real
// backend (see scripts/dump-demo.sh, output in assets/demo/).
//
// Reuses the production ApiClient by extending it and overriding the
// single `_send` seam. Every public method on the real client
// continues to work — it ends up routing through the lookup table
// below instead of Dio.
//
// Writes (POST / PUT / PATCH / DELETE) are accepted optimistically:
// the response is the same shape a successful real call would give,
// and the in-memory store is updated so subsequent reads reflect the
// "change". Refresh wipes everything because all state lives in this
// MockApiClient instance.
//
// `part of api_client` — needed so the override of the private
// `_send` method actually overrides (private members are
// library-scoped in Dart).

part of 'client.dart';

/// The role the demo visitor picked on the role picker. Drives which
/// identity `/me` returns and which seed dump (`owen_me.json`,
/// `dave_me.json`, `alex_me.json`) backs `/me/*` calls.
enum DemoRole { owner, instructor, student }

class MockApiClient extends ApiClient {
  final DemoRole _role;
  final Map<String, dynamic> _seed;
  // In-memory mutations: appended/replaced entries that take precedence
  // over the seed on subsequent reads. Key is the URL path.
  final Map<String, dynamic> _overrides = {};
  // Sub-collections built up by client writes — used so a write to
  // POST /bookings shows up in a follow-up GET /me/bookings.
  final List<Map<String, dynamic>> _newBookings = [];

  MockApiClient._(this._role, this._seed)
      : super(
          baseUrl: 'demo://',
          tokenSupplier: () async => null,
        );

  /// Construct an instance for the given role, loading every JSON file
  /// the dump-demo script produced into memory. Cheap — total payload
  /// is ~200 KB.
  static Future<MockApiClient> create(DemoRole role) async {
    final seed = <String, dynamic>{};
    // Order matters: load static catalog first, then role-specific
    // overrides so per-role files win on a key collision.
    const files = <String>[
      'schools', 'school',
      'locations', 'travel_times',
      'bikes', 'course_types', 'instructors', 'students',
      'signups_pending', 'disruptions', 'logistics', 'calendar',
      'instructor_pay_outstanding',
      'expense_categories',
      'expenses_review_pending', 'expenses_review_approved', 'expenses_review_reimbursed',
      'owen_me',
      'dave_me', 'dave_sessions', 'dave_me_expenses',
      'dave_availability', 'dave_time_off',
      'alex_me', 'alex_profile', 'alex_bookings', 'alex_notifications',
      'alex_sessions', 'alex_progress', 'alex_ledger',
    ];
    for (final f in files) {
      try {
        final raw = await rootBundle.loadString('assets/demo/$f.json');
        seed[f] = jsonDecode(raw);
      } catch (_) {
        // Missing file — okay; the lookup below falls back to 404.
      }
    }
    // Per-bike maintenance logs land in a sub-map.
    final bikeExpenses = <String, dynamic>{};
    final bikes = (seed['bikes'] as Map<String, dynamic>?)?['bikes'] as List? ?? const [];
    for (final b in bikes) {
      final bikeId = (b as Map<String, dynamic>)['id'];
      if (bikeId is! String) continue;
      try {
        final raw = await rootBundle.loadString('assets/demo/bike_expenses/$bikeId.json');
        bikeExpenses[bikeId] = jsonDecode(raw);
      } catch (_) {}
    }
    seed['_bike_expenses'] = bikeExpenses;
    return MockApiClient._(role, seed);
  }

  // --- The seam: every public method on ApiClient flows through this. ---
  @override
  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? query,
  }) async {
    final qs = query == null || query.isEmpty
        ? ''
        : '?${query.entries.map((e) => '${e.key}=${e.value}').join('&')}';
    final key = '$method $path$qs';

    // First, mutations.
    if (method == 'POST' || method == 'PUT' || method == 'PATCH' || method == 'DELETE') {
      return _applyWrite(method, path, data);
    }

    // GET / others — look up canned data.
    final body = _lookupGet(path, query);
    if (body == null) {
      // Surface as a clean 404 so the existing screen error-handlers
      // render the "couldn't load" path rather than crashing.
      return Response(
        data: {'error': 'not_seeded', 'message': 'No demo data for $key'},
        requestOptions: RequestOptions(path: path),
        statusCode: 404,
      );
    }
    return Response(
      data: body,
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
    );
  }

  // --- Read lookups ---

  dynamic _lookupGet(String path, Map<String, dynamic>? query) {
    // Override store first — anything a write produced.
    if (_overrides.containsKey(path)) return _overrides[path];

    switch (path) {
      case '/me':
        return _myMe();
      case '/me/student-profile':
        return _seed['alex_profile'];
      case '/me/bookings':
        // Merge newly-created bookings (from POST /bookings).
        final base = (_seed['alex_bookings'] as Map<String, dynamic>?) ?? {'bookings': []};
        final all = [..._newBookings, ...((base['bookings'] as List?) ?? const [])];
        return {'bookings': all};
      case '/me/notifications':
        return _seed['alex_notifications'];
      case '/me/expenses':
        return _seed['dave_me_expenses'];
      case '/school':
        return _seed['school'];
      case '/schools':
        return _seed['schools'];
      case '/locations':
        return _seed['locations'];
      case '/travel-times':
        return _seed['travel_times'];
      case '/bikes':
        return _seed['bikes'];
      case '/admin/bikes/gps':
        return _seed['bike_gps'] ?? _syntheticBikeGpsFromBikes();
      case '/course-types':
        return _seed['course_types'];
      case '/instructors':
        return _seed['instructors'];
      case '/students':
        return _seed['students'];
      case '/signups/pending':
        return _seed['signups_pending'];
      case '/disruptions':
        return _seed['disruptions'];
      case '/logistics':
        return _seed['logistics'];
      case '/calendar':
        return _seed['calendar'];
      case '/instructor-pay/outstanding':
        return _seed['instructor_pay_outstanding'];
      case '/expense-categories':
        return _seed['expense_categories'];
      case '/expenses':
        final status = query?['status']?.toString() ?? 'pending';
        return _seed['expenses_review_$status'];
      case '/sessions':
        return _role == DemoRole.student ? _seed['alex_sessions'] : _seed['dave_sessions'];
      case '/audit':
        // Demo mode has no real audit history — show an empty page so
        // the viewer paints "no activity in range" instead of crashing.
        return {'entries': <Map<String, dynamic>>[], 'total': 0};
      case '/me/waitlist':
        return {'entries': <Map<String, dynamic>>[]};
      case '/closures':
        return {'closures': <Map<String, dynamic>>[]};
      case '/followups':
        return {
          'followups': <Map<String, dynamic>>[],
          'counts': {'open': 0, 'overdue': 0},
        };
      case '/session-templates':
        // Demo has no templates seed; show empty so the page renders.
        return {'templates': <Map<String, dynamic>>[]};
      case '/session-templates/materialisations':
        return {'materialisations': <Map<String, dynamic>>[]};
      case '/revenue':
        // Demo-mode revenue — synthesise 6 months of plausible numbers
        // so the chart paints something rather than a blank state.
        final now = DateTime.now();
        final months = <Map<String, dynamic>>[];
        for (var i = 5; i >= 0; i--) {
          final dt = DateTime(now.year, now.month - i, 1);
          final key =
              '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}';
          months.add({
            'month': key,
            'billedPence': 280000 + i * 12000,
            'collectedPence': 240000 + i * 14000,
          });
        }
        return {
          'monthly': {'buckets': months, 'outstandingPence': 86000},
          'ageing': [
            {'label': '0–30 days', 'pence': 52000},
            {'label': '31–60 days', 'pence': 21000},
            {'label': '61–90 days', 'pence': 9000},
            {'label': '90+ days', 'pence': 4000},
          ],
          'byCourse': [
            {'courseTypeId': 'ct1', 'code': 'CBT-125', 'name': 'CBT 125', 'bookingCount': 48, 'billedPence': 624000},
            {'courseTypeId': 'ct2', 'code': 'MOD2', 'name': 'Practical', 'bookingCount': 18, 'billedPence': 360000},
            {'courseTypeId': 'ct3', 'code': 'TEST', 'name': 'Test day', 'bookingCount': 9, 'billedPence': 162000},
          ],
        };
      case '/compliance':
        // Synthesize a compliance payload from the seeded fleet so the
        // dashboard has something visible to show in demo mode.
        final bikes = (_seed['bikes'] as Map<String, dynamic>?)?['bikes']
                as List? ??
            const [];
        final bikeRows = bikes
            .cast<Map<String, dynamic>>()
            .map((b) => {
                  'id': b['id'] ?? '',
                  'nickname': b['nickname'] ?? '',
                  'registration': b['registration'] ?? '',
                  'motExpiresOn': b['motExpiresOn'] ?? '',
                  'motStatus': 'unknown',
                  'taxExpiresOn': b['taxExpiresOn'] ?? '',
                  'taxStatus': 'unknown',
                  'worstStatus': 'unknown',
                })
            .toList();
        return {
          'bikes': bikeRows,
          'instructors': const <Map<String, dynamic>>[],
          'school': {'insuranceExpiresOn': '', 'insuranceStatus': 'unknown'},
          'counts': {'expired': 0, 'urgent': 0, 'warn': 0, 'unknown': bikeRows.length},
        };
    }

    // Template preview — always zero in demo since templates are empty.
    if (RegExp(r'^/session-templates/[^/]+/preview$').hasMatch(path)) {
      return {'newSessions': 0};
    }

    // Session waitlist — demo dataset has no live waitlists.
    if (RegExp(r'^/sessions/[^/]+/waitlist$').hasMatch(path)) {
      return {'entries': <Map<String, dynamic>>[], 'count': 0};
    }

    // Incident follow-ups — empty in demo mode.
    if (RegExp(r'^/incidents/[^/]+/followups$').hasMatch(path)) {
      return {'followups': <Map<String, dynamic>>[]};
    }

    // Per-bike maintenance log.
    final bikeExp = RegExp(r'^/bikes/([^/]+)/expenses$').firstMatch(path);
    if (bikeExp != null) {
      final id = bikeExp.group(1)!;
      return (_seed['_bike_expenses'] as Map<String, dynamic>?)?[id];
    }

    // /students/{id}/progress, /ledger — Alex's only since we dumped his.
    if (path == '/students/${_studentId()}/progress') return _seed['alex_progress'];
    if (path == '/students/${_studentId()}/ledger') return _seed['alex_ledger'];

    // /instructors/{id}/availability, /time-off — Dave's only.
    if (path == '/instructors/${_instructorId()}/availability') return _seed['dave_availability'];
    if (path == '/instructors/${_instructorId()}/time-off') return _seed['dave_time_off'];

    return null;
  }

  // --- Write acceptance ---

  Response<dynamic> _applyWrite(String method, String path, Object? data) {
    // Most writes return either 204 No Content or an object. We accept
    // everything optimistically and return a shape the screens
    // tolerate. The DemoModeBanner makes it clear these aren't real.
    if (method == 'POST' && path == '/bookings') {
      final body = (data is Map) ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      final id = 'demo-bk-${DateTime.now().millisecondsSinceEpoch}';
      final booking = {
        'id': id,
        'sessionId': body['sessionId'] ?? '',
        'status': 'booked',
        'bikeId': 'demo-bike',
      };
      _newBookings.insert(0, booking);
      return Response(
        data: {'booking': booking},
        requestOptions: RequestOptions(path: path),
        statusCode: 201,
      );
    }
    if (method == 'POST' &&
        RegExp(r'^/session-templates/[^/]+/materialise$').hasMatch(path)) {
      return Response(
        data: {'materialisationId': '', 'created': 0},
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
      );
    }
    if (method == 'POST' && path == '/sessions') {
      return Response(
        data: {'id': 'demo-sess-${DateTime.now().millisecondsSinceEpoch}', 'warnings': []},
        requestOptions: RequestOptions(path: path),
        statusCode: 201,
      );
    }
    if (method == 'POST' && path == '/sessions/cancel-batch') {
      final body = (data is Map) ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      final ids = ((body['sessionIds'] as List?) ?? const []).length;
      return Response(
        data: {
          'results': [],
          'sessionsCancelled': ids,
          'bookingsCancelled': 0,
        },
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
      );
    }
    if (method == 'POST' && path == '/students') {
      // Demo-mode createStudent: synthesize an active student row in the
      // students-list shape so the admin screen can refresh without
      // crashing on the parse. Not persisted — the next refresh reverts
      // to the demo dataset.
      final body = (data is Map) ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      return Response(
        data: {
          'id': 'demo-stu-${DateTime.now().millisecondsSinceEpoch}',
          'name': body['name'] ?? '',
          'email': body['email'] ?? '',
          'phone': body['phone'] ?? '',
          'accountStatus': 'active',
          'licenceCategoryPursued': '',
          'transmissionPreference': '',
          'stage': 'Pre-CBT',
          'balancePence': 0,
          'completedBookings': 0,
          'safetyFlagCount': 0,
          'hasSafetyFlag': false,
          'passed': false,
        },
        requestOptions: RequestOptions(path: path),
        statusCode: 201,
      );
    }
    if (method == 'POST' && path == '/bikes') {
      // Demo-mode createBike: synthesize a ready bike at the requested
      // home location so the screen can refresh without crashing on the
      // response parse. Not persisted into the seed — the next refresh
      // reverts to the demo dataset, which is fine.
      final body = (data is Map) ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      final id = 'demo-bike-${DateTime.now().millisecondsSinceEpoch}';
      final homeId = (body['homeLocationId'] ?? '') as String;
      final locations =
          (_seed['locations'] as Map<String, dynamic>?)?['locations'] as List? ?? const [];
      final homeName = locations
              .cast<Map<String, dynamic>>()
              .firstWhere((l) => l['id'] == homeId, orElse: () => const {})['name'] ??
          '';
      return Response(
        data: {
          'id': id,
          'nickname': body['nickname'] ?? '',
          'make': body['make'] ?? '',
          'model': body['model'] ?? '',
          'registration': body['registration'] ?? '',
          'category': body['category'] ?? 'A1',
          'transmission': body['transmission'] ?? 'manual',
          'engineCc': body['engineCc'] ?? 0,
          'status': 'ready',
          'homeLocationId': homeId,
          'homeLocationName': homeName,
          'currentLocationId': homeId,
          'currentLocationName': homeName,
          'isCrossSite': false,
          'motExpiresOn': '',
          'taxExpiresOn': '',
          'currentMileageMiles': 0,
        },
        requestOptions: RequestOptions(path: path),
        statusCode: 201,
      );
    }
    if (method == 'POST' && path == '/me/expenses') {
      // The screen reads the response back; return a minimal expense
      // shape so it doesn't crash.
      return Response(
        data: {
          'expense': {
            'id': 'demo-exp-${DateTime.now().millisecondsSinceEpoch}',
            'amountPence': 0,
            'occurredAt': DateTime.now().toUtc().toIso8601String(),
            'categoryLabel': 'Demo entry',
            'categoryIcon': 'more-h',
            'categoryTone': 277,
            'instructorId': _instructorId(),
            'instructorName': 'Dave',
            'where': '',
            'notes': 'Demo mode — receipt not stored.',
            'status': 'pending',
            'submittedAt': DateTime.now().toUtc().toIso8601String(),
            'receiptContentType': 'image/jpeg',
            'receiptSizeBytes': 0,
            'reviewedByName': '',
            'reviewerNote': '',
            'paidByName': '',
            'paidMethod': '',
          },
        },
        requestOptions: RequestOptions(path: path),
        statusCode: 201,
      );
    }
    // Default — 204 No Content. Most PUT/PATCH/DELETE that we care about
    // (rename a bike, edit settings, withdraw an expense) succeed
    // silently and the next read just shows the seed value, which is
    // fine for a demo.
    return Response(
      data: null,
      requestOptions: RequestOptions(path: path),
      statusCode: 204,
    );
  }

  // --- /me dispatch by role ---

  Map<String, dynamic> _myMe() {
    switch (_role) {
      case DemoRole.owner:
        return _seed['owen_me'] as Map<String, dynamic>;
      case DemoRole.instructor:
        return _seed['dave_me'] as Map<String, dynamic>;
      case DemoRole.student:
        return _seed['alex_me'] as Map<String, dynamic>;
    }
  }

  String _studentId() => (_seed['alex_me'] as Map<String, dynamic>?)?['userId'] ?? 'user_stu';
  String _instructorId() => (_seed['dave_me'] as Map<String, dynamic>?)?['userId'] ?? 'user_instr';

  // Synthesises a plausible /admin/bikes/gps payload from whatever the
  // fleet seed has, so demo mode doesn't 404 the live-map screen even
  // when scripts/dump-demo.sh hasn't been re-run since the GPS endpoint
  // landed. Falls back to the canned bike_gps.json once it exists.
  Map<String, dynamic> _syntheticBikeGpsFromBikes() {
    final base = (_seed['bikes'] as Map<String, dynamic>?) ?? const {};
    final bikes = (base['bikes'] as List?) ?? const [];
    // Three demo site centroids so the map has visible markers.
    const sites = <String, List<double>>{
      'loc_belfast': [54.5825, -5.9655],
      'loc_lisburn': [54.5188, -6.0640],
      'loc_newry': [54.1750, -6.3380],
    };
    final out = <Map<String, dynamic>>[];
    final now = DateTime.now().toUtc().toIso8601String();
    for (final raw in bikes) {
      final b = (raw as Map).cast<String, dynamic>();
      final locId = (b['currentLocationId'] ?? b['homeLocationId'] ?? '').toString();
      final coords = sites[locId];
      final liveStatus = (b['status'] ?? '') == 'offline' ? 'offline' : 'available';
      out.add({
        'id': b['id'],
        'nickname': b['nickname'] ?? '',
        'registration': b['registration'] ?? '',
        'status': b['status'] ?? '',
        'liveStatus': liveStatus,
        'currentLocationId': locId,
        'currentLocationName': b['currentLocationName'] ?? '',
        if (coords != null) 'lat': coords[0] + (out.length % 5 - 2) * 0.003,
        if (coords != null) 'lng': coords[1] + (out.length % 7 - 3) * 0.003,
        'lastSeenAt': coords != null ? now : '',
      });
    }
    return {'bikes': out};
  }

  /// The identity the AuthController should pin in demo mode — derived
  /// from the same `/me` payload the real backend returns. Public so
  /// the demo auth controller can read it without a round-trip.
  Identity demoIdentity() => Identity.fromJson(_myMe());

  // currentToken is read by widgets (Image.network headers) — return a
  // bogus value so the headers exist; the mock doesn't validate it.
  @override
  String? currentToken() => 'demo-token';
}

