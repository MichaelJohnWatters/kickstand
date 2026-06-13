// API response models. Hand-written; we don't pull in code generation
// for this small surface.
//
// All from-JSON constructors are forgiving of missing/null fields — server
// responses evolve, and one missing field shouldn't crash a screen.

import 'dart:convert';
import 'dart:typed_data';

/// _decodeThumb turns the base64 receipt thumbnail the server inlines
/// in list payloads into bytes ready for `Image.memory`. Returns an
/// empty Uint8List when the field is missing or invalid — the list
/// cell falls back to its stripe placeholder.
Uint8List _decodeThumb(dynamic raw) {
  if (raw is! String || raw.isEmpty) return Uint8List(0);
  try {
    return base64Decode(raw);
  } catch (_) {
    return Uint8List(0);
  }
}

class Identity {
  final String userId;
  final String schoolId;
  final String role; // 'student' | 'instructor' | 'admin' | 'owner'
  final String accountStatus; // 'active' | 'pending_approval' | 'disabled'
  final String email;
  final String name;

  Identity({
    required this.userId,
    required this.schoolId,
    required this.role,
    required this.accountStatus,
    required this.email,
    required this.name,
  });

  factory Identity.fromJson(Map<String, dynamic> j) => Identity(
        userId: j['userId'] ?? '',
        schoolId: j['schoolId'] ?? '',
        role: j['role'] ?? '',
        accountStatus: j['accountStatus'] ?? '',
        email: j['email'] ?? '',
        name: j['name'] ?? '',
      );

  bool get isStudent => role == 'student';
  bool get isInstructor => role == 'instructor';
  bool get isAdmin => role == 'admin' || role == 'owner';
  bool get isPending => accountStatus == 'pending_approval';
}

class LoginResult {
  final String token;
  final DateTime expiresAt;
  final Identity identity;
  LoginResult({required this.token, required this.expiresAt, required this.identity});

  factory LoginResult.fromJson(Map<String, dynamic> j) => LoginResult(
        token: j['token'] ?? '',
        expiresAt: DateTime.tryParse(j['expiresAt'] ?? '') ?? DateTime.now(),
        identity: Identity.fromJson(j['identity'] ?? const {}),
      );
}

class SessionListing {
  final String sessionId;
  final String courseTypeId;
  final String courseCode;
  final String courseName;
  final String courseAccentColour; // hex string, "" → client fallback
  final bool nonTeaching;
  final String instructorId;
  final String instructorName;
  final String locationId;
  final String locationName;
  final DateTime startsAt;
  final DateTime endsAt;
  final int capacity;
  final int honestCapacity;
  final int suitableFreeBikes;
  final int pricePence;

  SessionListing({
    required this.sessionId,
    required this.courseTypeId,
    required this.courseCode,
    required this.courseName,
    required this.courseAccentColour,
    required this.nonTeaching,
    required this.instructorId,
    required this.instructorName,
    required this.locationId,
    required this.locationName,
    required this.startsAt,
    required this.endsAt,
    required this.capacity,
    required this.honestCapacity,
    required this.suitableFreeBikes,
    required this.pricePence,
  });

  factory SessionListing.fromJson(Map<String, dynamic> j) => SessionListing(
        sessionId: j['sessionId'] ?? '',
        courseTypeId: j['courseTypeId'] ?? '',
        courseCode: j['courseCode'] ?? '',
        courseName: j['courseName'] ?? '',
        courseAccentColour: j['courseAccentColour'] ?? '',
        nonTeaching: j['nonTeaching'] ?? false,
        instructorId: j['instructorId'] ?? '',
        instructorName: j['instructorName'] ?? '',
        locationId: j['locationId'] ?? '',
        locationName: j['locationName'] ?? '',
        startsAt: DateTime.tryParse(j['startsAt'] ?? '')?.toLocal() ?? DateTime.now(),
        endsAt: DateTime.tryParse(j['endsAt'] ?? '')?.toLocal() ?? DateTime.now(),
        capacity: j['capacity'] ?? 0,
        honestCapacity: j['honestCapacity'] ?? 0,
        suitableFreeBikes: j['suitableFreeBikes'] ?? 0,
        pricePence: j['pricePence'] ?? 0,
      );

  bool get isFull => honestCapacity <= 0;
  String get priceLabel {
    final pounds = pricePence ~/ 100;
    final pence = pricePence % 100;
    return pence == 0 ? '£$pounds' : '£$pounds.${pence.toString().padLeft(2, '0')}';
  }
}

/// One bike returned by GET /sessions/{id}/suitable-bikes — the booking
/// flow's bike picker. The engine filters by category, transmission (if a
/// preference is set), readiness, and overlap-free; cross-site bikes are
/// included with the [isCrossSite] flag so the UI can warn about a move.
class SuitableBike {
  final String bikeId;
  final String nickname;
  final String registration;
  final String category;
  final String transmission;
  final int engineCc;
  final String currentLocationId;
  final String currentLocationName;
  final bool isCrossSite;

  SuitableBike({
    required this.bikeId,
    required this.nickname,
    required this.registration,
    required this.category,
    required this.transmission,
    required this.engineCc,
    required this.currentLocationId,
    required this.currentLocationName,
    required this.isCrossSite,
  });

  factory SuitableBike.fromJson(Map<String, dynamic> j) => SuitableBike(
        bikeId: j['bikeId'] ?? '',
        nickname: j['nickname'] ?? '',
        registration: j['registration'] ?? '',
        category: j['category'] ?? '',
        transmission: j['transmission'] ?? '',
        engineCc: j['engineCc'] ?? 0,
        currentLocationId: j['currentLocationId'] ?? '',
        currentLocationName: j['currentLocationName'] ?? '',
        isCrossSite: j['isCrossSite'] ?? false,
      );
}

class Advisory {
  final String code;
  final String message;
  Advisory({required this.code, required this.message});
  factory Advisory.fromJson(Map<String, dynamic> j) =>
      Advisory(code: j['code'] ?? '', message: j['message'] ?? '');
}

class Booking {
  final String id;
  final String sessionId;
  final String studentId;
  final String bikeId;
  final String status;
  final DateTime createdAt;

  Booking({
    required this.id,
    required this.sessionId,
    required this.studentId,
    required this.bikeId,
    required this.status,
    required this.createdAt,
  });

  factory Booking.fromJson(Map<String, dynamic> j) => Booking(
        id: j['id'] ?? '',
        sessionId: j['sessionId'] ?? '',
        studentId: j['studentId'] ?? '',
        bikeId: j['bikeId'] ?? '',
        status: j['status'] ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] ?? '')?.toLocal() ?? DateTime.now(),
      );
}

class BookingResult {
  final Booking booking;
  final List<Advisory> advisories;
  BookingResult({required this.booking, required this.advisories});

  factory BookingResult.fromJson(Map<String, dynamic> j) => BookingResult(
        booking: Booking.fromJson(j['booking'] ?? const {}),
        advisories: ((j['advisories'] as List?) ?? const [])
            .map((e) => Advisory.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// ApiException carries the structured server error so screens can branch
/// on code (e.g. capacity_full, no_suitable_bike) and render the right copy.
///
/// `toString` returns just the human message — most error displays
/// interpolate `'$e'` directly, so the default rendering is already
/// user-friendly. Screens that care about the code can still read `.code`.
class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;
  ApiException(this.statusCode, this.code, this.message);

  @override
  String toString() => message;
}

/// Convert any error into a user-friendly one-line message. Use in error
/// builders / catch blocks where the error type might not be ApiException
/// (a stray Dio leak, a Riverpod assertion, etc.) — we never want to
/// surface a stack trace string to the end user.
String friendlyError(Object error) {
  if (error is ApiException) return error.message;
  // Anything else — keep the UI calm and ask them to retry.
  return 'Something went wrong. Try again in a moment.';
}

/// MyBooking is one row in the "My bookings" list. Carries enough
/// denormalised context (course, location, instructor, time) to render a
/// card without a second round-trip.
class MyBooking {
  final String bookingId;
  final String status; // booked | needs_reassignment | completed | no_show | cancelled
  final String bikeNickname;
  final String sessionId;
  final String courseCode;
  final String courseName;
  final String courseAccentColour;
  final bool nonTeaching;
  final String instructorName;
  final String locationName;
  final DateTime startsAt;
  final DateTime endsAt;
  final int pricePence;
  final DateTime? cancelledAt;
  final String cancelledBy;
  final String cancellationReason;

  MyBooking({
    required this.bookingId,
    required this.status,
    required this.bikeNickname,
    required this.sessionId,
    required this.courseCode,
    required this.courseName,
    required this.courseAccentColour,
    required this.nonTeaching,
    required this.instructorName,
    required this.locationName,
    required this.startsAt,
    required this.endsAt,
    required this.pricePence,
    this.cancelledAt,
    required this.cancelledBy,
    required this.cancellationReason,
  });

  factory MyBooking.fromJson(Map<String, dynamic> j) => MyBooking(
        bookingId: j['bookingId'] ?? '',
        status: j['status'] ?? '',
        bikeNickname: j['bikeNickname'] ?? '',
        sessionId: j['sessionId'] ?? '',
        courseCode: j['courseCode'] ?? '',
        courseName: j['courseName'] ?? '',
        courseAccentColour: j['courseAccentColour'] ?? '',
        nonTeaching: j['nonTeaching'] ?? false,
        instructorName: j['instructorName'] ?? '',
        locationName: j['locationName'] ?? '',
        startsAt: DateTime.tryParse(j['startsAt'] ?? '')?.toLocal() ?? DateTime.now(),
        endsAt: DateTime.tryParse(j['endsAt'] ?? '')?.toLocal() ?? DateTime.now(),
        pricePence: j['pricePence'] ?? 0,
        cancelledAt: DateTime.tryParse(j['cancelledAt'] ?? '')?.toLocal(),
        cancelledBy: j['cancelledBy'] ?? '',
        cancellationReason: j['cancellationReason'] ?? '',
      );

  bool get isCancelled => status == 'cancelled';
  bool get isCompleted => status == 'completed';
  bool get isNoShow => status == 'no_show';
  bool get needsReassignment => status == 'needs_reassignment';
  bool get isActive => status == 'booked' || status == 'needs_reassignment';
  bool get hasStarted => startsAt.isBefore(DateTime.now());
}

/// StudentProfile mirrors the /me/student-profile response. CBT variant +
/// expiry, theory status, the school's region label (DVA / DVSA).
class StudentProfile {
  final String provisionalLicenceNo;
  final String licenceCategoryPursued;
  final String dateOfBirth;
  final String transmissionPreference; // 'manual' | 'auto' | ''
  final bool cbtHeld;
  final String cbtVariant;
  final String cbtExpiresOn; // YYYY-MM-DD
  final String cbtRegion;
  final bool theoryPassed;
  final String theoryPassedOn;
  final String schoolRegion; // 'NI' | 'GB'
  final String testBodyLabel; // 'DVA' | 'DVSA'

  StudentProfile({
    required this.provisionalLicenceNo,
    required this.licenceCategoryPursued,
    required this.dateOfBirth,
    required this.transmissionPreference,
    required this.cbtHeld,
    required this.cbtVariant,
    required this.cbtExpiresOn,
    required this.cbtRegion,
    required this.theoryPassed,
    required this.theoryPassedOn,
    required this.schoolRegion,
    required this.testBodyLabel,
  });

  factory StudentProfile.fromJson(Map<String, dynamic> j) => StudentProfile(
        provisionalLicenceNo: j['provisionalLicenceNo'] ?? '',
        licenceCategoryPursued: j['licenceCategoryPursued'] ?? '',
        dateOfBirth: j['dateOfBirth'] ?? '',
        transmissionPreference: j['transmissionPreference'] ?? '',
        cbtHeld: j['cbtHeld'] ?? false,
        cbtVariant: j['cbtVariant'] ?? '',
        cbtExpiresOn: j['cbtExpiresOn'] ?? '',
        cbtRegion: j['cbtRegion'] ?? '',
        theoryPassed: j['theoryPassed'] ?? false,
        theoryPassedOn: j['theoryPassedOn'] ?? '',
        schoolRegion: j['schoolRegion'] ?? 'NI',
        testBodyLabel: j['testBodyLabel'] ?? 'DVA',
      );
}

/// One competency in the student progress rollup.
class CompetencyProgress {
  final String competencyId;
  final String label;
  final String status; // not_assessed | developing | competent | needs_work
  final DateTime? lastSeen;
  CompetencyProgress({
    required this.competencyId,
    required this.label,
    required this.status,
    this.lastSeen,
  });
  factory CompetencyProgress.fromJson(Map<String, dynamic> j) => CompetencyProgress(
        competencyId: j['competencyId'] ?? '',
        label: j['label'] ?? '',
        status: j['status'] ?? 'not_assessed',
        lastSeen: DateTime.tryParse(j['lastSeen'] ?? '')?.toLocal(),
      );
}

class CourseProgress {
  final String courseTypeId;
  final String courseName;
  final int totalCompetencies;
  final int competentCount;
  final int needsWorkCount;
  final List<CompetencyProgress> competencies;
  CourseProgress({
    required this.courseTypeId,
    required this.courseName,
    required this.totalCompetencies,
    required this.competentCount,
    required this.needsWorkCount,
    required this.competencies,
  });
  factory CourseProgress.fromJson(Map<String, dynamic> j) => CourseProgress(
        courseTypeId: j['courseTypeId'] ?? '',
        courseName: j['courseName'] ?? '',
        totalCompetencies: j['totalCompetencies'] ?? 0,
        competentCount: j['competentCount'] ?? 0,
        needsWorkCount: j['needsWorkCount'] ?? 0,
        competencies: ((j['competencies'] as List?) ?? const [])
            .map((e) => CompetencyProgress.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// External (DVA/DVSA) test entry — one row per attempt.
class ExternalTest {
  final String id;
  final String testType; // 'theory' | 'practical' | 'mod1' | 'mod2'
  final String region; // 'NI' | 'GB'
  final int attemptNumber;
  final DateTime? scheduledAt;
  final String reference;
  final String outcome; // booked | pass | fail | not_yet
  final String notes;

  ExternalTest({
    required this.id,
    required this.testType,
    required this.region,
    required this.attemptNumber,
    this.scheduledAt,
    required this.reference,
    required this.outcome,
    required this.notes,
  });

  factory ExternalTest.fromJson(Map<String, dynamic> j) => ExternalTest(
        id: j['id'] ?? '',
        testType: j['testType'] ?? '',
        region: j['region'] ?? 'NI',
        attemptNumber: j['attemptNumber'] ?? 1,
        scheduledAt: DateTime.tryParse(j['scheduledAt'] ?? '')?.toLocal(),
        reference: j['reference'] ?? '',
        outcome: j['outcome'] ?? 'booked',
        notes: j['notes'] ?? '',
      );
}

/// One notification row in the bell list.
class AppNotification {
  final String id;
  final String eventId;
  final String eventKind; // e.g. booking.created
  final String category;  // booking | disruption | payment | reminder
  final String status;    // sent | read | pending | failed
  final DateTime sentAt;
  final DateTime? readAt;
  final Map<String, dynamic> payload;

  AppNotification({
    required this.id,
    required this.eventId,
    required this.eventKind,
    required this.category,
    required this.status,
    required this.sentAt,
    this.readAt,
    required this.payload,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] ?? '',
        eventId: j['eventId'] ?? '',
        eventKind: j['eventKind'] ?? '',
        category: j['category'] ?? '',
        status: j['status'] ?? 'sent',
        sentAt: DateTime.tryParse(j['sentAt'] ?? '')?.toLocal() ?? DateTime.now(),
        readAt: DateTime.tryParse(j['readAt'] ?? '')?.toLocal(),
        payload: (j['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  bool get isRead => status == 'read';
}

class NotificationList {
  final List<AppNotification> notifications;
  final int unreadCount;
  NotificationList({required this.notifications, required this.unreadCount});

  factory NotificationList.fromJson(Map<String, dynamic> j) => NotificationList(
        notifications: ((j['notifications'] as List?) ?? const [])
            .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
            .toList(),
        unreadCount: j['unreadCount'] ?? 0,
      );
}

/// School-level settings the app needs to render conditional UI (e.g. the
/// in-field payment row only appears when instructorsCanRecordPayments is on).
/// Minimal school metadata for the signup picker. Returned by the public
/// GET /schools endpoint — no auth required, since prospective students
/// need to see the list before having an account.
class SchoolLite {
  final String id;
  final String name;
  final String region;
  const SchoolLite({required this.id, required this.name, required this.region});
  factory SchoolLite.fromJson(Map<String, dynamic> j) => SchoolLite(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        region: j['region'] ?? '',
      );
}

class SchoolSettings {
  final String name;
  final String region;
  final String testBodyLabel;
  final String onboardingMode;
  final bool instructorsCanRecordPayments;
  final int cancelCutoffHours;
  final int travelBufferMinutes;
  final int crossSiteNoticeHours;
  // Fleet warning thresholds — drive MOT/tax pill colours on the bike
  // cards. Defaults match the Go side's migration 0008 defaults so a
  // brand-new tenant gets sensible values without visiting Settings.
  final int motWarnDays;
  final int motUrgentDays;
  final int taxWarnDays;
  final int taxUrgentDays;
  // Compliance dashboard windows (annual cycles). Defaults match
  // migration 0015 so a brand-new tenant gets sensible values.
  final int accreditationWarnDays;
  final int accreditationUrgentDays;
  final int insuranceWarnDays;
  final int insuranceUrgentDays;

  SchoolSettings({
    required this.name,
    required this.region,
    required this.testBodyLabel,
    required this.onboardingMode,
    required this.instructorsCanRecordPayments,
    required this.cancelCutoffHours,
    required this.travelBufferMinutes,
    required this.crossSiteNoticeHours,
    required this.motWarnDays,
    required this.motUrgentDays,
    required this.taxWarnDays,
    required this.taxUrgentDays,
    required this.accreditationWarnDays,
    required this.accreditationUrgentDays,
    required this.insuranceWarnDays,
    required this.insuranceUrgentDays,
  });

  factory SchoolSettings.fromJson(Map<String, dynamic> j) => SchoolSettings(
        name: j['name'] ?? '',
        region: j['region'] ?? 'NI',
        testBodyLabel: j['testBodyLabel'] ?? 'DVA',
        onboardingMode: j['onboardingMode'] ?? 'open',
        instructorsCanRecordPayments: j['instructorsCanRecordPayments'] ?? false,
        cancelCutoffHours: j['cancelCutoffHours'] ?? 48,
        travelBufferMinutes: j['travelBufferMinutes'] ?? 15,
        crossSiteNoticeHours: j['crossSiteNoticeHours'] ?? 12,
        motWarnDays: (j['motWarnDays'] as num?)?.toInt() ?? 90,
        motUrgentDays: (j['motUrgentDays'] as num?)?.toInt() ?? 14,
        taxWarnDays: (j['taxWarnDays'] as num?)?.toInt() ?? 30,
        taxUrgentDays: (j['taxUrgentDays'] as num?)?.toInt() ?? 7,
        accreditationWarnDays:
            (j['accreditationWarnDays'] as num?)?.toInt() ?? 90,
        accreditationUrgentDays:
            (j['accreditationUrgentDays'] as num?)?.toInt() ?? 30,
        insuranceWarnDays:
            (j['insuranceWarnDays'] as num?)?.toInt() ?? 60,
        insuranceUrgentDays:
            (j['insuranceUrgentDays'] as num?)?.toInt() ?? 14,
      );
}

/// One row from /bikes/{id}/expenses — per-bike maintenance log.
/// Sibling shape to [Expense] but without the approval workflow
/// fields (recorded → done, no review cycle).
class BikeExpense {
  final String id;
  final String bikeId;
  final String category; // parts | labour | mot | tax | service | other
  final int amountPence;
  final String occurredAt; // YYYY-MM-DD
  final String vendor;
  final String notes;
  final String receiptContentType;
  final int receiptSizeBytes;
  final Uint8List receiptThumbBytes;
  final String recordedById;
  final String recordedByName;
  final DateTime recordedAt;

  const BikeExpense({
    required this.id,
    required this.bikeId,
    required this.category,
    required this.amountPence,
    required this.occurredAt,
    required this.vendor,
    required this.notes,
    required this.receiptContentType,
    required this.receiptSizeBytes,
    required this.receiptThumbBytes,
    required this.recordedById,
    required this.recordedByName,
    required this.recordedAt,
  });

  factory BikeExpense.fromJson(Map<String, dynamic> j) => BikeExpense(
        id: j['id'] ?? '',
        bikeId: j['bikeId'] ?? '',
        category: j['category'] ?? 'other',
        amountPence: (j['amountPence'] as num?)?.toInt() ?? 0,
        occurredAt: j['occurredAt'] ?? '',
        vendor: j['vendor'] ?? '',
        notes: j['notes'] ?? '',
        receiptContentType: j['receiptContentType'] ?? 'image/jpeg',
        receiptSizeBytes: (j['receiptSizeBytes'] as num?)?.toInt() ?? 0,
        receiptThumbBytes: _decodeThumb(j['receiptThumb']),
        recordedById: j['recordedBy'] ?? '',
        recordedByName: j['recordedByName'] ?? '',
        recordedAt: DateTime.tryParse(j['recordedAt'] ?? '')?.toLocal() ?? DateTime.now(),
      );
}

/// Wrapper for GET /bikes/{id}/expenses — list + the year-to-date
/// total used by the fleet card's £xxx YTD pill.
class BikeExpensesPayload {
  final List<BikeExpense> expenses;
  final int ytdPence;
  const BikeExpensesPayload({required this.expenses, required this.ytdPence});
  factory BikeExpensesPayload.fromJson(Map<String, dynamic> j) => BikeExpensesPayload(
        expenses: ((j['expenses'] as List?) ?? const [])
            .map((e) => BikeExpense.fromJson(e as Map<String, dynamic>))
            .toList(),
        ytdPence: (j['ytdPence'] as num?)?.toInt() ?? 0,
      );
}

/// One row from /locations — used to drive the location picker on the
/// availability editor, the admin Locations cards, and anywhere else
/// a site is rendered.
///
/// `imageBytes` is the optional ~300×120 banner JPEG the server inlines
/// as base64 in the list payload. Empty for rows seeded before
/// migration 0007. Decoded uses the shared `_decodeThumb` helper so a
/// malformed payload becomes empty bytes, never a crash.
class LocationLite {
  final String id;
  final String name;
  final String address;
  final Uint8List imageBytes;
  final double? lat;
  final double? lng;
  LocationLite({
    required this.id,
    required this.name,
    required this.address,
    required this.imageBytes,
    this.lat,
    this.lng,
  });
  bool get hasCoords => lat != null && lng != null;
  factory LocationLite.fromJson(Map<String, dynamic> j) => LocationLite(
        id: j['ID'] ?? j['id'] ?? '',
        name: j['Name'] ?? j['name'] ?? '',
        address: j['Address'] ?? j['address'] ?? '',
        imageBytes: _decodeThumb(j['image'] ?? j['Image']),
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
      );
}

/// One recurring weekly availability slot for an instructor.
class RecurringSlot {
  final String id;
  final String instructorId;
  final int weekday; // 0 = Sunday … 6 = Saturday
  final String startsAtLocal; // 'HH:MM'
  final String endsAtLocal;   // 'HH:MM'
  final String locationId;    // may be empty
  RecurringSlot({
    required this.id,
    required this.instructorId,
    required this.weekday,
    required this.startsAtLocal,
    required this.endsAtLocal,
    required this.locationId,
  });
  factory RecurringSlot.fromJson(Map<String, dynamic> j) => RecurringSlot(
        id: j['id'] ?? '',
        instructorId: j['instructorId'] ?? '',
        weekday: j['weekday'] ?? 0,
        startsAtLocal: j['startsAtLocal'] ?? '',
        endsAtLocal: j['endsAtLocal'] ?? '',
        locationId: j['locationId'] ?? '',
      );
}

/// Pending applicant — the manager approval queue row. Also reused for
/// the Rejected and Approved tabs (approvedAt is null except on
/// Approved rows).
class PendingApplicant {
  final String userId;
  final String name;
  final String email;
  final String phone;
  final String licenceCategoryPursued;
  final String dateOfBirth; // YYYY-MM-DD
  final String transmissionPreference;
  final String signupNote; // optional free-text the applicant left
  final DateTime signedUpAt;
  final DateTime? approvedAt;
  PendingApplicant({
    required this.userId,
    required this.name,
    required this.email,
    required this.phone,
    required this.licenceCategoryPursued,
    required this.dateOfBirth,
    required this.transmissionPreference,
    required this.signupNote,
    required this.signedUpAt,
    this.approvedAt,
  });
  factory PendingApplicant.fromJson(Map<String, dynamic> j) => PendingApplicant(
        userId: j['userId'] ?? '',
        name: j['name'] ?? '',
        email: j['email'] ?? '',
        phone: j['phone'] ?? '',
        licenceCategoryPursued: j['licenceCategoryPursued'] ?? '',
        dateOfBirth: j['dateOfBirth'] ?? '',
        transmissionPreference: j['transmissionPreference'] ?? '',
        signupNote: j['signupNote'] ?? '',
        signedUpAt: DateTime.tryParse(j['signedUpAt'] ?? '')?.toLocal() ?? DateTime.now(),
        approvedAt: j['approvedAt'] == null
            ? null
            : DateTime.tryParse(j['approvedAt'])?.toLocal(),
      );
}

/// Travel-matrix row.
class TravelTime {
  final String fromLocationId;
  final String toLocationId;
  final int minutes;
  TravelTime({required this.fromLocationId, required this.toLocationId, required this.minutes});
  factory TravelTime.fromJson(Map<String, dynamic> j) => TravelTime(
        fromLocationId: j['fromLocationId'] ?? '',
        toLocationId: j['toLocationId'] ?? '',
        minutes: (j['minutes'] as num?)?.toInt() ?? 0,
      );
}

/// Full course-type row (admin Course types screen).
class CourseTypeFull {
  final String id;
  final String code;
  final String name;
  final String region;
  final String requiredBikeCategory;
  final int durationMinutes;
  final int maxRatio;
  final int pricePence;
  final bool nonTeaching;
  final int cancellationCutoffHours;
  final String accentColour;
  final String icon;
  final List<String> prerequisites;
  CourseTypeFull({
    required this.id,
    required this.code,
    required this.name,
    required this.region,
    required this.requiredBikeCategory,
    required this.durationMinutes,
    required this.maxRatio,
    required this.pricePence,
    required this.nonTeaching,
    required this.cancellationCutoffHours,
    required this.accentColour,
    required this.icon,
    required this.prerequisites,
  });
  factory CourseTypeFull.fromJson(Map<String, dynamic> j) => CourseTypeFull(
        id: j['id'] ?? '',
        code: j['code'] ?? '',
        name: j['name'] ?? '',
        region: j['region'] ?? '',
        requiredBikeCategory: j['requiredBikeCategory'] ?? '',
        durationMinutes: (j['durationMinutes'] as num?)?.toInt() ?? 0,
        maxRatio: (j['maxRatio'] as num?)?.toInt() ?? 0,
        pricePence: (j['pricePence'] as num?)?.toInt() ?? 0,
        nonTeaching: j['nonTeaching'] ?? false,
        cancellationCutoffHours: (j['cancellationCutoffHours'] as num?)?.toInt() ?? 0,
        accentColour: j['accentColour'] ?? '',
        icon: j['icon'] ?? '',
        prerequisites: ((j['prerequisites'] as List?) ?? const []).cast<String>(),
      );
}

class Competency {
  final String id;
  final String courseTypeId;
  final String label;
  final int sortOrder;
  Competency({
    required this.id,
    required this.courseTypeId,
    required this.label,
    required this.sortOrder,
  });
  factory Competency.fromJson(Map<String, dynamic> j) => Competency(
        id: j['id'] ?? '',
        courseTypeId: j['courseTypeId'] ?? '',
        label: j['label'] ?? '',
        sortOrder: (j['sortOrder'] as num?)?.toInt() ?? 0,
      );
}

/// Light course-type row used by the qualifications + earning pickers.
class CourseTypeLite {
  final String id;
  final String code;
  final String name;
  final String region;
  final String requiredBikeCategory;
  final bool nonTeaching;
  final int pricePence;
  /// Hex string (`#RRGGBB`) set by the school in the course-type editor.
  /// Empty when not configured — UI falls back to a code-derived colour.
  final String accentColour;
  CourseTypeLite({
    required this.id,
    required this.code,
    required this.name,
    required this.region,
    required this.requiredBikeCategory,
    required this.nonTeaching,
    required this.pricePence,
    required this.accentColour,
  });
  factory CourseTypeLite.fromJson(Map<String, dynamic> j) => CourseTypeLite(
        id: j['id'] ?? '',
        code: j['code'] ?? '',
        name: j['name'] ?? '',
        region: j['region'] ?? '',
        requiredBikeCategory: j['requiredBikeCategory'] ?? '',
        nonTeaching: j['nonTeaching'] ?? false,
        pricePence: (j['pricePence'] as num?)?.toInt() ?? 0,
        accentColour: j['accentColour'] ?? '',
      );
}

/// One (course, expiry-date) entry on an instructor's record.
/// `expiresOn` is "YYYY-MM-DD" or empty when the date is unknown.
class Accreditation {
  final String courseTypeId;
  final String expiresOn;
  const Accreditation({required this.courseTypeId, required this.expiresOn});
  factory Accreditation.fromJson(Map<String, dynamic> j) => Accreditation(
        courseTypeId: j['courseTypeId'] ?? '',
        expiresOn: j['expiresOn'] ?? '',
      );
  Map<String, dynamic> toJson() => {
        'courseTypeId': courseTypeId,
        'expiresOn': expiresOn,
      };
}

/// Admin instructors list row.
class InstructorRow {
  final String userId;
  final String name;
  final String email;
  final String phone;
  final String homeLocationId;
  final String homeLocationName;
  final String accountStatus;
  final List<Accreditation> accreditations;
  InstructorRow({
    required this.userId,
    required this.name,
    required this.email,
    required this.phone,
    required this.homeLocationId,
    required this.homeLocationName,
    required this.accountStatus,
    required this.accreditations,
  });

  List<String> get qualifiedCourseIds =>
      accreditations.map((a) => a.courseTypeId).toList(growable: false);

  factory InstructorRow.fromJson(Map<String, dynamic> j) => InstructorRow(
        userId: j['userId'] ?? '',
        name: j['name'] ?? '',
        email: j['email'] ?? '',
        phone: j['phone'] ?? '',
        homeLocationId: j['homeLocationId'] ?? '',
        homeLocationName: j['homeLocationName'] ?? '',
        accountStatus: j['accountStatus'] ?? '',
        accreditations: ((j['accreditations'] as List?) ?? const [])
            .map((e) => Accreditation.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Pay model for an instructor.
class PayModel {
  final String instructorId;
  final String payBasis; // percentage|per_day|per_session|per_hour|per_student|salary
  final int rateValue; // pence for flat; basis-points (10000 = 100%) for percentage
  PayModel({required this.instructorId, required this.payBasis, required this.rateValue});
  factory PayModel.fromJson(Map<String, dynamic> j) => PayModel(
        instructorId: j['instructorId'] ?? '',
        payBasis: j['payBasis'] ?? '',
        rateValue: (j['rateValue'] as num?)?.toInt() ?? 0,
      );
}

/// One row in the "what we owe instructors" admin screen.
class InstructorPayRow {
  final String instructorId;
  final String instructorName;
  final int totalEarnedPence;
  final int totalPaidPence;
  final int outstandingPence;
  InstructorPayRow({
    required this.instructorId,
    required this.instructorName,
    required this.totalEarnedPence,
    required this.totalPaidPence,
    required this.outstandingPence,
  });
  factory InstructorPayRow.fromJson(Map<String, dynamic> j) => InstructorPayRow(
        instructorId: j['instructorId'] ?? '',
        instructorName: j['instructorName'] ?? '',
        totalEarnedPence: (j['totalEarnedPence'] as num?)?.toInt() ?? 0,
        totalPaidPence: (j['totalPaidPence'] as num?)?.toInt() ?? 0,
        outstandingPence: (j['outstandingPence'] as num?)?.toInt() ?? 0,
      );
}

/// One row in the admin students list.
class StudentRow {
  final String id;
  final String name;
  final String email;
  final String phone;
  final String accountStatus;
  final String licenceCategoryPursued;
  final String transmissionPreference;
  final String stage; // human-readable training stage (server-computed)
  final int balancePence;
  final int completedBookings;
  final int safetyFlagCount;
  final bool passed; // has a passing final-practical test on record
  StudentRow({
    required this.id,
    required this.name,
    required this.email,
    required this.phone,
    required this.accountStatus,
    required this.licenceCategoryPursued,
    required this.transmissionPreference,
    required this.stage,
    required this.balancePence,
    required this.completedBookings,
    required this.safetyFlagCount,
    required this.passed,
  });
  factory StudentRow.fromJson(Map<String, dynamic> j) => StudentRow(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        email: j['email'] ?? '',
        phone: j['phone'] ?? '',
        accountStatus: j['accountStatus'] ?? '',
        licenceCategoryPursued: j['licenceCategoryPursued'] ?? '',
        transmissionPreference: j['transmissionPreference'] ?? '',
        stage: j['stage'] ?? '',
        balancePence: (j['balancePence'] as num?)?.toInt() ?? 0,
        completedBookings: (j['completedBookings'] as num?)?.toInt() ?? 0,
        safetyFlagCount: (j['safetyFlagCount'] as num?)?.toInt() ??
            ((j['hasSafetyFlag'] == true) ? 1 : 0),
        passed: j['passed'] == true,
      );
  bool get hasSafetyFlag => safetyFlagCount > 0;
}

/// One row from the bike fleet list (admin Fleet screen).
class FleetBike {
  final String id;
  final String nickname;
  final String make;
  final String model;
  final String registration;
  final String category;     // A1 | A2 | A
  final String transmission; // manual | auto
  final int engineCc;
  final String status;       // ready | offline | in_use
  final String homeLocationId;
  final String homeLocationName;
  final String currentLocationId;
  final String currentLocationName;
  final bool isCrossSite;
  // Chunk 2 state — empty / 0 when unknown. Status is derived
  // client-side using SchoolSettings thresholds to keep the warning
  // bucketing reactive to settings changes without a backend refetch.
  final String motExpiresOn; // YYYY-MM-DD, '' = unknown
  final String taxExpiresOn; // YYYY-MM-DD, '' = unknown
  final int currentMileageMiles; // 0 = unknown
  FleetBike({
    required this.id,
    required this.nickname,
    required this.make,
    required this.model,
    required this.registration,
    required this.category,
    required this.transmission,
    required this.engineCc,
    required this.status,
    required this.homeLocationId,
    required this.homeLocationName,
    required this.currentLocationId,
    required this.currentLocationName,
    required this.isCrossSite,
    required this.motExpiresOn,
    required this.taxExpiresOn,
    required this.currentMileageMiles,
  });
  factory FleetBike.fromJson(Map<String, dynamic> j) => FleetBike(
        id: j['id'] ?? '',
        nickname: j['nickname'] ?? '',
        make: j['make'] ?? '',
        model: j['model'] ?? '',
        registration: j['registration'] ?? '',
        category: j['category'] ?? '',
        transmission: j['transmission'] ?? '',
        engineCc: j['engineCc'] ?? 0,
        status: j['status'] ?? '',
        homeLocationId: j['homeLocationId'] ?? '',
        homeLocationName: j['homeLocationName'] ?? '',
        currentLocationId: j['currentLocationId'] ?? '',
        currentLocationName: j['currentLocationName'] ?? '',
        isCrossSite: j['isCrossSite'] ?? false,
        motExpiresOn: j['motExpiresOn'] ?? '',
        taxExpiresOn: j['taxExpiresOn'] ?? '',
        currentMileageMiles: (j['currentMileageMiles'] as num?)?.toInt() ?? 0,
      );
}

/// One time-off window for an instructor.
class TimeOff {
  final String id;
  final String instructorId;
  final DateTime startsAt;
  final DateTime endsAt;
  final String reason;
  TimeOff({
    required this.id,
    required this.instructorId,
    required this.startsAt,
    required this.endsAt,
    required this.reason,
  });
  factory TimeOff.fromJson(Map<String, dynamic> j) => TimeOff(
        id: j['id'] ?? '',
        instructorId: j['instructorId'] ?? '',
        startsAt: DateTime.tryParse(j['startsAt'] ?? '')?.toLocal() ?? DateTime.now(),
        endsAt: DateTime.tryParse(j['endsAt'] ?? '')?.toLocal() ?? DateTime.now(),
        reason: j['reason'] ?? '',
      );
}

/// One row of the per-school category list. Owner curates these from the
/// admin Reimbursements page; instructors choose one when submitting.
class ExpenseCategory {
  final String id;
  final String label;
  final String icon;
  final int tone;
  final bool active;
  final int sortOrder;
  const ExpenseCategory({
    required this.id,
    required this.label,
    required this.icon,
    required this.tone,
    required this.active,
    required this.sortOrder,
  });
  factory ExpenseCategory.fromJson(Map<String, dynamic> j) => ExpenseCategory(
        id: j['id'] ?? '',
        label: j['label'] ?? '',
        icon: j['icon'] ?? 'more-h',
        tone: (j['tone'] as num?)?.toInt() ?? 277,
        active: j['active'] ?? true,
        sortOrder: (j['sortOrder'] as num?)?.toInt() ?? 0,
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'icon': icon,
        'tone': tone,
        'active': active,
        'sortOrder': sortOrder,
      };
}

/// One reimbursable expense, in any state. The status string is one of
/// `pending`, `approved`, `rejected`, `reimbursed`, `withdrawn`.
class Expense {
  final String id;
  final String instructorId;
  final String instructorName;
  final String categoryId;
  final String categoryLabel;
  final String categoryIcon;
  final int categoryTone;
  final int amountPence;
  final DateTime occurredAt;
  final String where;
  final String notes;
  final String status;
  final String receiptContentType;
  final int receiptSizeBytes;
  // Inline 50×50 JPEG thumbnail decoded from the base64 the server
  // ships in the list payload. Empty until the server attaches one.
  final Uint8List receiptThumbBytes;
  final DateTime submittedAt;
  final String reviewedByName;
  final DateTime? reviewedAt;
  final String reviewerNote;
  final String paidByName;
  final DateTime? paidAt;
  final String paidMethod;

  const Expense({
    required this.id,
    required this.instructorId,
    required this.instructorName,
    required this.categoryId,
    required this.categoryLabel,
    required this.categoryIcon,
    required this.categoryTone,
    required this.amountPence,
    required this.occurredAt,
    required this.where,
    required this.notes,
    required this.status,
    required this.receiptContentType,
    required this.receiptSizeBytes,
    required this.receiptThumbBytes,
    required this.submittedAt,
    required this.reviewedByName,
    required this.reviewedAt,
    required this.reviewerNote,
    required this.paidByName,
    required this.paidAt,
    required this.paidMethod,
  });

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        id: j['id'] ?? '',
        instructorId: j['instructorId'] ?? '',
        instructorName: j['instructorName'] ?? '',
        categoryId: j['categoryId'] ?? '',
        categoryLabel: j['categoryLabel'] ?? '',
        categoryIcon: j['categoryIcon'] ?? 'more-h',
        categoryTone: (j['categoryTone'] as num?)?.toInt() ?? 277,
        amountPence: (j['amountPence'] as num?)?.toInt() ?? 0,
        occurredAt: DateTime.tryParse(j['occurredAt'] ?? '')?.toLocal() ?? DateTime.now(),
        where: j['where'] ?? '',
        notes: j['notes'] ?? '',
        status: j['status'] ?? 'pending',
        receiptContentType: j['receiptContentType'] ?? 'image/jpeg',
        receiptSizeBytes: (j['receiptSizeBytes'] as num?)?.toInt() ?? 0,
        receiptThumbBytes: _decodeThumb(j['receiptThumb']),
        submittedAt: DateTime.tryParse(j['submittedAt'] ?? '')?.toLocal() ?? DateTime.now(),
        reviewedByName: j['reviewedByName'] ?? '',
        reviewedAt: DateTime.tryParse(j['reviewedAt'] ?? '')?.toLocal(),
        reviewerNote: j['reviewerNote'] ?? '',
        paidByName: j['paidByName'] ?? '',
        paidAt: DateTime.tryParse(j['paidAt'] ?? '')?.toLocal(),
        paidMethod: j['paidMethod'] ?? '',
      );
}

/// Wrapper returned by GET /me/expenses — list + the "Awaiting
/// reimbursement" hero totals (count + sum of pending+approved).
class MyExpensesPayload {
  final List<Expense> expenses;
  final int outstandingCount;
  final int outstandingAmountPence;
  const MyExpensesPayload({
    required this.expenses,
    required this.outstandingCount,
    required this.outstandingAmountPence,
  });
  factory MyExpensesPayload.fromJson(Map<String, dynamic> j) => MyExpensesPayload(
        expenses: ((j['expenses'] as List?) ?? const [])
            .map((e) => Expense.fromJson(e as Map<String, dynamic>))
            .toList(),
        outstandingCount: ((j['outstanding'] as Map?)?['count'] as num?)?.toInt() ?? 0,
        outstandingAmountPence:
            ((j['outstanding'] as Map?)?['amountPence'] as num?)?.toInt() ?? 0,
      );
}

/// Wrapper returned by GET /expenses — admin queue + pending count.
class ExpensesQueuePayload {
  final List<Expense> expenses;
  final int pendingCount;
  const ExpensesQueuePayload({required this.expenses, required this.pendingCount});
  factory ExpensesQueuePayload.fromJson(Map<String, dynamic> j) => ExpensesQueuePayload(
        expenses: ((j['expenses'] as List?) ?? const [])
            .map((e) => Expense.fromJson(e as Map<String, dynamic>))
            .toList(),
        pendingCount: (j['pendingCount'] as num?)?.toInt() ?? 0,
      );
}

/// One row of the admin audit log. Mirrors the wire shape from
/// `GET /audit` (one row per authenticated mutation).
class AuditEntry {
  final String id;
  final DateTime at;
  final String actorUserId;
  final String actorRole;
  final String actorName;
  final String method;
  final String pathPattern;
  final String targetEntity;
  final String targetId;
  /// Server-resolved human label for the target (e.g. a bike's
  /// nickname, a student's name). Empty when the entity is gone or
  /// the route doesn't have a single named target.
  final String targetLabel;
  /// Handler-set one-sentence summary, populated via audit.Describe on
  /// the backend. Preferred over the client-side verb mapping when set.
  final String summary;
  final int statusCode;
  final String errorCode;
  const AuditEntry({
    required this.id,
    required this.at,
    required this.actorUserId,
    required this.actorRole,
    required this.actorName,
    required this.method,
    required this.pathPattern,
    required this.targetEntity,
    required this.targetId,
    required this.targetLabel,
    required this.summary,
    required this.statusCode,
    required this.errorCode,
  });
  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        id: j['id'] ?? '',
        at: DateTime.tryParse(j['at'] ?? '')?.toLocal() ?? DateTime.now(),
        actorUserId: j['actorUserId'] ?? '',
        actorRole: j['actorRole'] ?? '',
        actorName: j['actorName'] ?? '',
        method: j['method'] ?? '',
        pathPattern: j['pathPattern'] ?? '',
        targetEntity: j['targetEntity'] ?? '',
        targetId: j['targetId'] ?? '',
        targetLabel: j['targetLabel'] ?? '',
        summary: j['summary'] ?? '',
        statusCode: (j['statusCode'] as num?)?.toInt() ?? 0,
        errorCode: j['errorCode'] ?? '',
      );

  bool get succeeded => statusCode >= 200 && statusCode < 400;
}

/// One row of the compliance dashboard — a bike's MOT + tax view.
class ComplianceBike {
  final String id;
  final String nickname;
  final String registration;
  final String motExpiresOn;
  final String motStatus; // unknown | ok | due_soon | due_urgent | expired
  final String taxExpiresOn;
  final String taxStatus;
  final String worstStatus;
  const ComplianceBike({
    required this.id,
    required this.nickname,
    required this.registration,
    required this.motExpiresOn,
    required this.motStatus,
    required this.taxExpiresOn,
    required this.taxStatus,
    required this.worstStatus,
  });
  factory ComplianceBike.fromJson(Map<String, dynamic> j) => ComplianceBike(
        id: j['id'] ?? '',
        nickname: j['nickname'] ?? '',
        registration: j['registration'] ?? '',
        motExpiresOn: j['motExpiresOn'] ?? '',
        motStatus: j['motStatus'] ?? 'unknown',
        taxExpiresOn: j['taxExpiresOn'] ?? '',
        taxStatus: j['taxStatus'] ?? 'unknown',
        worstStatus: j['worstStatus'] ?? 'unknown',
      );
}

class ComplianceAccreditation {
  final String courseTypeId;
  final String courseCode;
  final String courseName;
  final String expiresOn;
  final String status;
  const ComplianceAccreditation({
    required this.courseTypeId,
    required this.courseCode,
    required this.courseName,
    required this.expiresOn,
    required this.status,
  });
  factory ComplianceAccreditation.fromJson(Map<String, dynamic> j) =>
      ComplianceAccreditation(
        courseTypeId: j['courseTypeId'] ?? '',
        courseCode: j['courseCode'] ?? '',
        courseName: j['courseName'] ?? '',
        expiresOn: j['expiresOn'] ?? '',
        status: j['status'] ?? 'unknown',
      );
}

class ComplianceInstructor {
  final String userId;
  final String name;
  final List<ComplianceAccreditation> accreditations;
  final String worstStatus;
  const ComplianceInstructor({
    required this.userId,
    required this.name,
    required this.accreditations,
    required this.worstStatus,
  });
  factory ComplianceInstructor.fromJson(Map<String, dynamic> j) =>
      ComplianceInstructor(
        userId: j['userId'] ?? '',
        name: j['name'] ?? '',
        accreditations: ((j['accreditations'] as List?) ?? const [])
            .map((e) => ComplianceAccreditation.fromJson(e as Map<String, dynamic>))
            .toList(),
        worstStatus: j['worstStatus'] ?? 'unknown',
      );
}

class ComplianceReport {
  final List<ComplianceBike> bikes;
  final List<ComplianceInstructor> instructors;
  final String insuranceExpiresOn;
  final String insuranceStatus;
  final int expiredCount;
  final int urgentCount;
  final int warnCount;
  final int unknownCount;
  const ComplianceReport({
    required this.bikes,
    required this.instructors,
    required this.insuranceExpiresOn,
    required this.insuranceStatus,
    required this.expiredCount,
    required this.urgentCount,
    required this.warnCount,
    required this.unknownCount,
  });
  factory ComplianceReport.fromJson(Map<String, dynamic> j) {
    final school = (j['school'] as Map<String, dynamic>?) ?? const {};
    final counts = (j['counts'] as Map<String, dynamic>?) ?? const {};
    return ComplianceReport(
      bikes: ((j['bikes'] as List?) ?? const [])
          .map((e) => ComplianceBike.fromJson(e as Map<String, dynamic>))
          .toList(),
      instructors: ((j['instructors'] as List?) ?? const [])
          .map((e) => ComplianceInstructor.fromJson(e as Map<String, dynamic>))
          .toList(),
      insuranceExpiresOn: school['insuranceExpiresOn'] ?? '',
      insuranceStatus: school['insuranceStatus'] ?? 'unknown',
      expiredCount: (counts['expired'] as num?)?.toInt() ?? 0,
      urgentCount: (counts['urgent'] as num?)?.toInt() ?? 0,
      warnCount: (counts['warn'] as num?)?.toInt() ?? 0,
      unknownCount: (counts['unknown'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One row in the session-templates list.
class SessionTemplate {
  final String id;
  final String courseTypeId;
  final String courseCode;
  final String courseName;
  final String instructorId;
  final String instructorName;
  final String locationId;
  final String locationName;
  final int weekday; // 0..6
  final String startsAtTime; // HH:MM
  final int durationMinutes;
  final int capacity;
  final String startsOn;
  final String endsOn;
  final String notes;
  const SessionTemplate({
    required this.id,
    required this.courseTypeId,
    required this.courseCode,
    required this.courseName,
    required this.instructorId,
    required this.instructorName,
    required this.locationId,
    required this.locationName,
    required this.weekday,
    required this.startsAtTime,
    required this.durationMinutes,
    required this.capacity,
    required this.startsOn,
    required this.endsOn,
    required this.notes,
  });
  factory SessionTemplate.fromJson(Map<String, dynamic> j) => SessionTemplate(
        id: j['id'] ?? '',
        courseTypeId: j['courseTypeId'] ?? '',
        courseCode: j['courseCode'] ?? '',
        courseName: j['courseName'] ?? '',
        instructorId: j['instructorId'] ?? '',
        instructorName: j['instructorName'] ?? '',
        locationId: j['locationId'] ?? '',
        locationName: j['locationName'] ?? '',
        weekday: (j['weekday'] as num?)?.toInt() ?? 0,
        startsAtTime: j['startsAtTime'] ?? '',
        durationMinutes: (j['durationMinutes'] as num?)?.toInt() ?? 0,
        capacity: (j['capacity'] as num?)?.toInt() ?? 0,
        startsOn: j['startsOn'] ?? '',
        endsOn: j['endsOn'] ?? '',
        notes: j['notes'] ?? '',
      );
}

/// One monthly bucket from GET /revenue (billed vs collected).
class RevenueMonth {
  final String month; // YYYY-MM
  final int billedPence;
  final int collectedPence;
  const RevenueMonth({
    required this.month,
    required this.billedPence,
    required this.collectedPence,
  });
  factory RevenueMonth.fromJson(Map<String, dynamic> j) => RevenueMonth(
        month: j['month'] ?? '',
        billedPence: (j['billedPence'] as num?)?.toInt() ?? 0,
        collectedPence: (j['collectedPence'] as num?)?.toInt() ?? 0,
      );
}

class AgeingBucket {
  final String label;
  final int pence;
  const AgeingBucket({required this.label, required this.pence});
  factory AgeingBucket.fromJson(Map<String, dynamic> j) => AgeingBucket(
        label: j['label'] ?? '',
        pence: (j['pence'] as num?)?.toInt() ?? 0,
      );
}

class RevenueByCourse {
  final String courseTypeId;
  final String code;
  final String name;
  final int bookingCount;
  final int billedPence;
  const RevenueByCourse({
    required this.courseTypeId,
    required this.code,
    required this.name,
    required this.bookingCount,
    required this.billedPence,
  });
  factory RevenueByCourse.fromJson(Map<String, dynamic> j) => RevenueByCourse(
        courseTypeId: j['courseTypeId'] ?? '',
        code: j['code'] ?? '',
        name: j['name'] ?? '',
        bookingCount: (j['bookingCount'] as num?)?.toInt() ?? 0,
        billedPence: (j['billedPence'] as num?)?.toInt() ?? 0,
      );
}

class RevenueReport {
  final List<RevenueMonth> monthly;
  final int outstandingPence;
  final List<AgeingBucket> ageing;
  final List<RevenueByCourse> byCourse;
  const RevenueReport({
    required this.monthly,
    required this.outstandingPence,
    required this.ageing,
    required this.byCourse,
  });
  factory RevenueReport.fromJson(Map<String, dynamic> j) {
    final m = (j['monthly'] as Map<String, dynamic>?) ?? const {};
    return RevenueReport(
      monthly: ((m['buckets'] as List?) ?? const [])
          .map((e) => RevenueMonth.fromJson(e as Map<String, dynamic>))
          .toList(),
      outstandingPence: (m['outstandingPence'] as num?)?.toInt() ?? 0,
      ageing: ((j['ageing'] as List?) ?? const [])
          .map((e) => AgeingBucket.fromJson(e as Map<String, dynamic>))
          .toList(),
      byCourse: ((j['byCourse'] as List?) ?? const [])
          .map((e) => RevenueByCourse.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class AuditPage {
  final List<AuditEntry> entries;
  final int total;
  const AuditPage({required this.entries, required this.total});
  factory AuditPage.fromJson(Map<String, dynamic> j) => AuditPage(
        entries: ((j['entries'] as List?) ?? const [])
            .map((e) => AuditEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}

/// One bike's live-map row. lat/lng are null when the bike has never
/// reported a fix — the map UI plots those in the off-map "no signal"
/// panel. liveStatus is derived server-side and is the source of
/// truth for marker colour.
class BikeGPS {
  final String id;
  final String nickname;
  final String registration;
  final String status;              // raw DB status (ready/offline/in_use)
  final String liveStatus;          // available / in_session / offline / needs_attention
  final String currentLocationId;
  final String currentLocationName;
  final double? lat;
  final double? lng;
  final String lastSeenAt;          // RFC3339; empty when never seen

  const BikeGPS({
    required this.id,
    required this.nickname,
    required this.registration,
    required this.status,
    required this.liveStatus,
    required this.currentLocationId,
    required this.currentLocationName,
    required this.lat,
    required this.lng,
    required this.lastSeenAt,
  });

  bool get hasFix => lat != null && lng != null;

  factory BikeGPS.fromJson(Map<String, dynamic> j) => BikeGPS(
        id: j['id'] ?? '',
        nickname: j['nickname'] ?? '',
        registration: j['registration'] ?? '',
        status: j['status'] ?? '',
        liveStatus: j['liveStatus'] ?? 'available',
        currentLocationId: j['currentLocationId'] ?? '',
        currentLocationName: j['currentLocationName'] ?? '',
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        lastSeenAt: j['lastSeenAt'] ?? '',
      );
}

/// One historical GPS fix for a single bike, returned by
/// /bikes/{id}/gps/history. Used to render the breadcrumb trail on
/// the live-map screen.
class GpsFix {
  final DateTime at;
  final double lat;
  final double lng;
  const GpsFix({required this.at, required this.lat, required this.lng});
  factory GpsFix.fromJson(Map<String, dynamic> j) => GpsFix(
        at: DateTime.parse(j['at'] as String).toUtc(),
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
      );
}

// ----- Analytics -----

/// One bike's utilisation row from /admin/analytics/bike-utilisation.
class BikeUtilisationRow {
  final String bikeId;
  final String nickname;
  final String registration;
  final int sessionsCount;
  final int bookedMinutes;
  final int availableMinutes;
  final double utilisationPct;
  final String lastSessionAt;
  const BikeUtilisationRow({
    required this.bikeId,
    required this.nickname,
    required this.registration,
    required this.sessionsCount,
    required this.bookedMinutes,
    required this.availableMinutes,
    required this.utilisationPct,
    required this.lastSessionAt,
  });
  factory BikeUtilisationRow.fromJson(Map<String, dynamic> j) => BikeUtilisationRow(
        bikeId: j['bikeId'] ?? '',
        nickname: j['nickname'] ?? '',
        registration: j['registration'] ?? '',
        sessionsCount: (j['sessionsCount'] as num?)?.toInt() ?? 0,
        bookedMinutes: (j['bookedMinutes'] as num?)?.toInt() ?? 0,
        availableMinutes: (j['availableMinutes'] as num?)?.toInt() ?? 0,
        utilisationPct: (j['utilisationPct'] as num?)?.toDouble() ?? 0,
        lastSessionAt: j['lastSessionAt'] ?? '',
      );
}

class InstructorUtilisationRow {
  final String instructorId;
  final String name;
  final int sessionsTaught;
  final int hoursTaughtX10; // tenths of an hour
  final int earnedPence;
  final int paidPence;
  final int outstandingPence;
  final List<int> weeklyTrend;
  const InstructorUtilisationRow({
    required this.instructorId,
    required this.name,
    required this.sessionsTaught,
    required this.hoursTaughtX10,
    required this.earnedPence,
    required this.paidPence,
    required this.outstandingPence,
    required this.weeklyTrend,
  });
  double get hoursTaught => hoursTaughtX10 / 10.0;
  factory InstructorUtilisationRow.fromJson(Map<String, dynamic> j) =>
      InstructorUtilisationRow(
        instructorId: j['instructorId'] ?? '',
        name: j['name'] ?? '',
        sessionsTaught: (j['sessionsTaught'] as num?)?.toInt() ?? 0,
        hoursTaughtX10: (j['hoursTaughtX10'] as num?)?.toInt() ?? 0,
        earnedPence: (j['earnedPence'] as num?)?.toInt() ?? 0,
        paidPence: (j['paidPence'] as num?)?.toInt() ?? 0,
        outstandingPence: (j['outstandingPence'] as num?)?.toInt() ?? 0,
        weeklyTrend: ((j['weeklyTrend'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
      );
}

class InstructorPassRate {
  final String instructorId;
  final String name;
  final int attempts;
  final int passes;
  final double passPct;
  const InstructorPassRate({
    required this.instructorId,
    required this.name,
    required this.attempts,
    required this.passes,
    required this.passPct,
  });
  factory InstructorPassRate.fromJson(Map<String, dynamic> j) => InstructorPassRate(
        instructorId: j['instructorId'] ?? '',
        name: j['name'] ?? '',
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        passes: (j['passes'] as num?)?.toInt() ?? 0,
        passPct: (j['passPct'] as num?)?.toDouble() ?? 0,
      );
}

class FunnelStats {
  final double signupToFirstBookingPct;
  final int signupSample;
  final double cbtCompletionPct;
  final int cbtSample;
  final double theoryPassPct;
  final int theorySample;
  final double practicalPassPct;
  final int practicalSample;
  final List<InstructorPassRate> perInstructorPassRate;
  const FunnelStats({
    required this.signupToFirstBookingPct,
    required this.signupSample,
    required this.cbtCompletionPct,
    required this.cbtSample,
    required this.theoryPassPct,
    required this.theorySample,
    required this.practicalPassPct,
    required this.practicalSample,
    required this.perInstructorPassRate,
  });
  factory FunnelStats.fromJson(Map<String, dynamic> j) => FunnelStats(
        signupToFirstBookingPct:
            (j['signupToFirstBookingPct'] as num?)?.toDouble() ?? 0,
        signupSample: (j['signupSample'] as num?)?.toInt() ?? 0,
        cbtCompletionPct: (j['cbtCompletionPct'] as num?)?.toDouble() ?? 0,
        cbtSample: (j['cbtSample'] as num?)?.toInt() ?? 0,
        theoryPassPct: (j['theoryPassPct'] as num?)?.toDouble() ?? 0,
        theorySample: (j['theorySample'] as num?)?.toInt() ?? 0,
        practicalPassPct: (j['practicalPassPct'] as num?)?.toDouble() ?? 0,
        practicalSample: (j['practicalSample'] as num?)?.toInt() ?? 0,
        perInstructorPassRate: ((j['perInstructorPassRate'] as List?) ?? const [])
            .map((e) => InstructorPassRate.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// One waitlist entry from /me/waitlist. The server denormalises
/// session details so the student-facing card can render without an
/// N+1 fetch per row.
class MyWaitlistEntry {
  final String id;
  final String sessionId;
  final DateTime joinedAt;
  final int position; // 1-based
  final DateTime sessionStartsAt;
  final String courseCode;
  final String courseName;
  final String courseAccent;
  final String locationName;
  const MyWaitlistEntry({
    required this.id,
    required this.sessionId,
    required this.joinedAt,
    required this.position,
    required this.sessionStartsAt,
    required this.courseCode,
    required this.courseName,
    required this.courseAccent,
    required this.locationName,
  });
  factory MyWaitlistEntry.fromJson(Map<String, dynamic> j) => MyWaitlistEntry(
        id: j['id'] ?? '',
        sessionId: j['sessionId'] ?? '',
        joinedAt: DateTime.tryParse(j['joinedAt'] ?? '') ?? DateTime.now(),
        position: (j['position'] as num?)?.toInt() ?? 0,
        sessionStartsAt:
            DateTime.tryParse(j['sessionStartsAt'] ?? '') ?? DateTime.now(),
        courseCode: j['courseCode'] ?? '',
        courseName: j['courseName'] ?? '',
        courseAccent: j['courseAccent'] ?? '',
        locationName: j['locationName'] ?? '',
      );
}

/// Per-category notification preferences. One row per category;
/// channel flags indicate which delivery channels are subscribed.
/// Defaults: in_app/email/push on, sms off (paid channel never
/// auto-enables).
class NotificationPrefs {
  final String category; // booking | disruption | payment | reminder
  final bool inApp;
  final bool email;
  final bool push;
  final bool sms;
  const NotificationPrefs({
    required this.category,
    required this.inApp,
    required this.email,
    required this.push,
    required this.sms,
  });

  NotificationPrefs copyWith({bool? inApp, bool? email, bool? push, bool? sms}) =>
      NotificationPrefs(
        category: category,
        inApp: inApp ?? this.inApp,
        email: email ?? this.email,
        push: push ?? this.push,
        sms: sms ?? this.sms,
      );

  factory NotificationPrefs.fromJson(Map<String, dynamic> j) => NotificationPrefs(
        category: j['category'] ?? '',
        inApp: j['inApp'] == true,
        email: j['email'] == true,
        push: j['push'] == true,
        sms: j['sms'] == true,
      );

  Map<String, dynamic> toJson() => {
        'category': category,
        'inApp': inApp,
        'email': email,
        'push': push,
        'sms': sms,
      };
}
