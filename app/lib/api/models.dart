// API response models. Hand-written; we don't pull in code generation
// for this small surface.
//
// All from-JSON constructors are forgiving of missing/null fields — server
// responses evolve, and one missing field shouldn't crash a screen.

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
class SchoolSettings {
  final String name;
  final String region;
  final String testBodyLabel;
  final String onboardingMode;
  final bool instructorsCanRecordPayments;
  final int cancelCutoffHours;
  final int travelBufferMinutes;
  final int crossSiteNoticeHours;

  SchoolSettings({
    required this.name,
    required this.region,
    required this.testBodyLabel,
    required this.onboardingMode,
    required this.instructorsCanRecordPayments,
    required this.cancelCutoffHours,
    required this.travelBufferMinutes,
    required this.crossSiteNoticeHours,
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
      );
}

/// One row from /locations — used to drive the location picker on the
/// availability editor.
class LocationLite {
  final String id;
  final String name;
  final String address;
  LocationLite({required this.id, required this.name, required this.address});
  factory LocationLite.fromJson(Map<String, dynamic> j) => LocationLite(
        id: j['ID'] ?? j['id'] ?? '',
        name: j['Name'] ?? j['name'] ?? '',
        address: j['Address'] ?? j['address'] ?? '',
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

/// Pending applicant — the manager approval queue row.
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

/// Admin instructors list row.
class InstructorRow {
  final String userId;
  final String name;
  final String email;
  final String phone;
  final String homeLocationId;
  final String homeLocationName;
  final String accountStatus;
  final List<String> qualifiedCourseIds;
  InstructorRow({
    required this.userId,
    required this.name,
    required this.email,
    required this.phone,
    required this.homeLocationId,
    required this.homeLocationName,
    required this.accountStatus,
    required this.qualifiedCourseIds,
  });
  factory InstructorRow.fromJson(Map<String, dynamic> j) => InstructorRow(
        userId: j['userId'] ?? '',
        name: j['name'] ?? '',
        email: j['email'] ?? '',
        phone: j['phone'] ?? '',
        homeLocationId: j['homeLocationId'] ?? '',
        homeLocationName: j['homeLocationName'] ?? '',
        accountStatus: j['accountStatus'] ?? '',
        qualifiedCourseIds: ((j['qualifiedCourseIds'] as List?) ?? const []).cast<String>(),
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
