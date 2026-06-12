// Bike MOT/tax warning bucketing — mirrors internal/admin/bike_warnings.go.
//
// Computed client-side from the date strings the server ships so the
// UI reacts immediately when the manager changes a threshold in
// Settings, without waiting for a list refresh.

enum BikeWarning { unknown, ok, dueSoon, dueUrgent, expired }

/// Bucket a YYYY-MM-DD expiry against today + per-school thresholds.
///
/// Returns:
///   - [BikeWarning.unknown] when [expires] is empty or unparseable.
///   - [BikeWarning.expired] when expiry ≤ today.
///   - [BikeWarning.dueUrgent] when days remaining ≤ urgentDays.
///   - [BikeWarning.dueSoon]   when days remaining ≤ warnDays.
///   - [BikeWarning.ok]        otherwise.
BikeWarning bucketExpiry(String expires, {
  required int warnDays,
  required int urgentDays,
  DateTime? now,
}) {
  if (expires.isEmpty) return BikeWarning.unknown;
  final parsed = DateTime.tryParse(expires);
  if (parsed == null) return BikeWarning.unknown;
  final today = (now ?? DateTime.now()).toLocal();
  // Calendar-day diff — strip time-of-day from both sides.
  final t0 = DateTime(today.year, today.month, today.day);
  final t1 = DateTime(parsed.year, parsed.month, parsed.day);
  final days = t1.difference(t0).inDays;
  if (days <= 0) return BikeWarning.expired;
  if (days <= urgentDays) return BikeWarning.dueUrgent;
  if (days <= warnDays) return BikeWarning.dueSoon;
  return BikeWarning.ok;
}

/// Human label for a parsed bucket — what the pill says.
String warningLabel(BikeWarning w, {required String expires}) {
  switch (w) {
    case BikeWarning.unknown:
      return 'Unknown';
    case BikeWarning.expired:
      return 'Expired';
    case BikeWarning.dueUrgent:
      final days = _daysUntil(expires);
      return days <= 0 ? 'Expired' : 'Due in $days day${days == 1 ? '' : 's'}';
    case BikeWarning.dueSoon:
      final days = _daysUntil(expires);
      return 'Due in $days day${days == 1 ? '' : 's'}';
    case BikeWarning.ok:
      return 'OK';
  }
}

int _daysUntil(String expires) {
  final parsed = DateTime.tryParse(expires);
  if (parsed == null) return 0;
  final now = DateTime.now();
  final t0 = DateTime(now.year, now.month, now.day);
  final t1 = DateTime(parsed.year, parsed.month, parsed.day);
  return t1.difference(t0).inDays;
}
