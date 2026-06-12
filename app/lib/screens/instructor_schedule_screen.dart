// Instructor schedule — Day / Week toggle. Uses GET /calendar (auto-scoped
// to the caller's own sessions for instructors). Tapping a session card
// opens session detail.
//
// Visual structure mirrors the design handoff (`instructor.jsx`):
//   - Day view: a "Today" pill + day label, then session cards with a
//     coloured left stripe, course code in mono, course name large,
//     meta row (time / location / count), and a pile of student avatars.
//   - Week view: a 7-row mini-calendar with day-number bubbles and
//     compact tinted session chips per day.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../state/providers.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../util/course_colour.dart';
import '../widgets/ks_avatar.dart';
import '../widgets/notification_bell.dart';

enum ScheduleMode { day, week }

/// Who's sessions to show. "mine" filters to the logged-in instructor;
/// "all" shows every session in the school for the window.
enum ScheduleScope { mine, all }

/// (mode, dayOffset). dayOffset is days from today; week mode uses the
/// monday-of containing today + offset*7.
final scheduleModeProvider = StateProvider<ScheduleMode>((_) => ScheduleMode.day);
final scheduleOffsetProvider = StateProvider<int>((_) => 0);
final scheduleScopeProvider = StateProvider<ScheduleScope>((_) => ScheduleScope.mine);

final scheduleSessionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final api = ref.read(apiClientProvider);
  final mode = ref.watch(scheduleModeProvider);
  final offset = ref.watch(scheduleOffsetProvider);
  final scope = ref.watch(scheduleScopeProvider);
  final auth = ref.read(authControllerProvider);
  final now = DateTime.now();
  late DateTime from, to;
  if (mode == ScheduleMode.day) {
    final base = DateTime(now.year, now.month, now.day).add(Duration(days: offset));
    from = base;
    to = base.add(const Duration(days: 1));
  } else {
    // Monday-of-this-week (Dart: weekday 1=Mon)
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    from = monday.add(Duration(days: offset * 7));
    to = from.add(const Duration(days: 7));
  }
  // Server-side filter when scoped to me — keeps the payload small
  // and avoids leaking other instructors' rosters when the Mine
  // toggle is active. All-mode sends no instructorId so the school
  // calendar comes back whole.
  final instructorId = scope == ScheduleScope.mine ? auth.identity?.userId : null;
  return api.calendar(from: from, to: to, instructorId: instructorId);
});

class InstructorScheduleScreen extends ConsumerWidget {
  const InstructorScheduleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(scheduleModeProvider);
    final offset = ref.watch(scheduleOffsetProvider);
    final async = ref.watch(scheduleSessionsProvider);
    final auth = ref.watch(authControllerProvider);

    return Scaffold(
      backgroundColor: KsColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: KsColors.primary,
          onRefresh: () async => ref.invalidate(scheduleSessionsProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            children: [
              _Header(name: auth.identity?.name ?? ''),
              const SizedBox(height: 14),
              _ModeSwitch(),
              const SizedBox(height: 10),
              _ScopeSwitch(),
              const SizedBox(height: 14),
              _DateNav(mode: mode, offset: offset),
              const SizedBox(height: 12),
              async.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Couldn’t load.\n$e',
                      style: const TextStyle(color: KsColors.danger)),
                ),
                data: (sessions) {
                  // Server already scopes to me when the Mine toggle is on
                  // (via the instructorId query param). On All we render
                  // the full school schedule.
                  final list = sessions;
                  if (list.isEmpty) {
                    return _EmptyState(mode: mode);
                  }
                  if (mode == ScheduleMode.day) {
                    return _DayBody(sessions: list);
                  }
                  return _WeekBody(sessions: list, weekOffset: offset);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  final String name;
  const _Header({required this.name});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: KsColors.ink3)),
              const SizedBox(height: 2),
              Text('Schedule',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: KsColors.ink,
                      letterSpacing: -0.6,
                      height: 1.05)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const NotificationBell(),
        const SizedBox(width: 4),
        KsAvatar(name: name, size: 40),
      ],
    );
  }
}

class _ModeSwitch extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(scheduleModeProvider);
    return Container(
      decoration: BoxDecoration(
        color: KsColors.surface3,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(children: [
        Expanded(child: _opt(ref, ScheduleMode.day, mode, 'Day')),
        Expanded(child: _opt(ref, ScheduleMode.week, mode, 'Week')),
      ]),
    );
  }

  Widget _opt(WidgetRef ref, ScheduleMode value, ScheduleMode current, String label) {
    final active = value == current;
    return GestureDetector(
      onTap: () => ref.read(scheduleModeProvider.notifier).state = value,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? KsColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          boxShadow: active ? KsShadows.sh1 : null,
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w800,
              color: active ? KsColors.ink : KsColors.ink3,
              fontSize: 13.5,
            )),
      ),
    );
  }
}

/// Mine / All scope filter. Sits under the Day/Week toggle so the
/// shape's familiar, but using a compact ChoiceChip-y row with an
/// icon to differentiate the two switches at a glance.
class _ScopeSwitch extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(scheduleScopeProvider);
    return Row(children: [
      _opt(ref, ScheduleScope.mine, scope, 'Mine', Icons.person_outline),
      const SizedBox(width: 8),
      _opt(ref, ScheduleScope.all, scope, 'All instructors',
          Icons.groups_outlined),
    ]);
  }

  Widget _opt(WidgetRef ref, ScheduleScope value, ScheduleScope current,
      String label, IconData icon) {
    final active = value == current;
    return InkWell(
      onTap: () => ref.read(scheduleScopeProvider.notifier).state = value,
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? KsColors.primaryTint : KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(
              color: active
                  ? KsColors.primary.withValues(alpha: 0.5)
                  : KsColors.border,
              width: active ? 1.5 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 14,
              color: active ? KsColors.primaryDeep : KsColors.ink3),
          const SizedBox(width: 6),
          Text(label,
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w800,
                color: active ? KsColors.primaryDeep : KsColors.ink3,
                fontSize: 12.5,
              )),
        ]),
      ),
    );
  }
}

class _DateNav extends ConsumerWidget {
  final ScheduleMode mode;
  final int offset;
  const _DateNav({required this.mode, required this.offset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        _navBtn(Icons.chevron_left,
            () => ref.read(scheduleOffsetProvider.notifier).state = offset - 1),
        const SizedBox(width: 8),
        Expanded(
          child: GestureDetector(
            onTap: () => ref.read(scheduleOffsetProvider.notifier).state = 0,
            child: Center(
              child: Text(_label(mode, offset),
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: KsColors.ink)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _navBtn(Icons.chevron_right,
            () => ref.read(scheduleOffsetProvider.notifier).state = offset + 1),
      ],
    );
  }

  Widget _navBtn(IconData icon, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KsRadius.md),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: KsColors.surface,
            border: Border.all(color: KsColors.border),
            borderRadius: BorderRadius.circular(KsRadius.md),
          ),
          child: Icon(icon, color: KsColors.ink2, size: 18),
        ),
      );

  String _label(ScheduleMode mode, int offset) {
    final now = DateTime.now();
    if (mode == ScheduleMode.day) {
      final base = DateTime(now.year, now.month, now.day).add(Duration(days: offset));
      return DateFormat('EEEE d MMM').format(base);
    }
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    final from = monday.add(Duration(days: offset * 7));
    final to = from.add(const Duration(days: 6));
    return offset == 0
        ? 'This week'
        : '${DateFormat('d MMM').format(from)} – ${DateFormat('d MMM').format(to)}';
  }
}

class _DayBody extends StatelessWidget {
  final List<Map<String, dynamic>> sessions;
  const _DayBody({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    sessions.sort((a, b) {
      final ta = DateTime.tryParse(a['startsAt'] ?? '') ?? now;
      final tb = DateTime.tryParse(b['startsAt'] ?? '') ?? now;
      return ta.compareTo(tb);
    });
    final live = sessions.where((s) {
      final start = DateTime.tryParse(s['startsAt'] ?? '')?.toLocal();
      final end = DateTime.tryParse(s['endsAt'] ?? '')?.toLocal();
      return start != null && end != null && now.isAfter(start) && now.isBefore(end);
    }).toSet();
    return Column(
      children: [
        for (var i = 0; i < sessions.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _SessionCard(s: sessions[i], live: live.contains(sessions[i])),
        ],
      ],
    );
  }
}

class _SessionCard extends StatelessWidget {
  final Map<String, dynamic> s;
  final bool live;
  const _SessionCard({required this.s, required this.live});

  @override
  Widget build(BuildContext context) {
    final code = (s['courseCode'] ?? '').toString();
    final hex = (s['courseAccentColour'] ?? '').toString();
    final colour = courseColour(code, hex);
    final name = (s['courseName'] ?? '').toString();
    final location = (s['locationName'] ?? '').toString();
    final startsAt = DateTime.tryParse(s['startsAt'] ?? '')?.toLocal();
    final endsAt = DateTime.tryParse(s['endsAt'] ?? '')?.toLocal();
    final tf = DateFormat('HH:mm');
    final timeStr = (startsAt == null || endsAt == null)
        ? ''
        : '${tf.format(startsAt)}–${tf.format(endsAt)}';
    final activeBookings = (s['activeBookings'] ?? 0) as int;
    final students = ((s['students'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final id = (s['sessionId'] ?? s['id'] ?? '').toString();
    final instructorName = (s['instructorName'] ?? '').toString();

    return InkWell(
      onTap: () => context.push('/instructor/session/$id'),
      borderRadius: BorderRadius.circular(KsRadius.lg),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(KsRadius.lg),
        child: Container(
          decoration: BoxDecoration(
            color: KsColors.surface,
            border: Border.all(color: KsColors.border),
            boxShadow: KsShadows.sh1,
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 5, color: colour),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(15),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Text(code,
                              style: ksMono(
                                  size: 10.5,
                                  weight: FontWeight.w800,
                                  color: colour)),
                          const SizedBox(width: 8),
                          if (live) _liveBadge(),
                          const Spacer(),
                          const Icon(Icons.chevron_right,
                              color: KsColors.ink4, size: 20),
                        ]),
                        const SizedBox(height: 2),
                        Text(name,
                            style: GoogleFonts.plusJakartaSans(
                                fontSize: 16.5,
                                fontWeight: FontWeight.w800,
                                color: KsColors.ink,
                                letterSpacing: -0.3)),
                        const SizedBox(height: 11),
                        Wrap(
                          spacing: 15,
                          runSpacing: 7,
                          children: [
                            _meta(Icons.schedule_outlined, timeStr),
                            if (location.isNotEmpty)
                              _meta(Icons.place_outlined, location),
                            if (instructorName.isNotEmpty)
                              _meta(Icons.person_outline, instructorName),
                            _meta(Icons.people_outline,
                                '${activeBookings == 0 ? students.length : activeBookings} student${(activeBookings == 1 || students.length == 1) ? '' : 's'}'),
                          ],
                        ),
                        if (students.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _AvatarPile(students: students),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: KsColors.ink3),
          const SizedBox(width: 5),
          Text(text,
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: KsColors.ink2)),
        ],
      );

  Widget _liveBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: KsColors.successTint,
          borderRadius: BorderRadius.circular(KsRadius.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
                color: KsColors.success, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text('In progress',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: KsColors.success)),
        ]),
      );
}

class _AvatarPile extends StatelessWidget {
  final List<Map<String, dynamic>> students;
  const _AvatarPile({required this.students});

  @override
  Widget build(BuildContext context) {
    final shown = students.take(5).toList();
    final overflow = students.length - shown.length;
    return SizedBox(
      height: 28,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * 20.0,
              child: KsAvatar(
                  name: (shown[i]['name'] ?? '').toString(),
                  size: 28,
                  ring: true),
            ),
          if (overflow > 0)
            Positioned(
              left: shown.length * 20.0,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: KsColors.surface3,
                  shape: BoxShape.circle,
                  border: Border.all(color: KsColors.surface, width: 2),
                ),
                alignment: Alignment.center,
                child: Text('+$overflow',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink3)),
              ),
            ),
        ],
      ),
    );
  }
}

class _WeekBody extends StatelessWidget {
  final List<Map<String, dynamic>> sessions;
  final int weekOffset;
  const _WeekBody({required this.sessions, required this.weekOffset});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1))
        .add(Duration(days: weekOffset * 7));
    final today = DateTime(now.year, now.month, now.day);
    return Column(
      children: [
        for (var i = 0; i < 7; i++)
          _WeekRow(
            day: monday.add(Duration(days: i)),
            isToday: monday.add(Duration(days: i)) == today,
            sessions: sessions.where((s) {
              final t = DateTime.tryParse(s['startsAt'] ?? '')?.toLocal();
              if (t == null) return false;
              final d = DateTime(t.year, t.month, t.day);
              return d == monday.add(Duration(days: i));
            }).toList(),
          ),
      ],
    );
  }
}

class _WeekRow extends StatelessWidget {
  final DateTime day;
  final bool isToday;
  final List<Map<String, dynamic>> sessions;
  const _WeekRow({required this.day, required this.isToday, required this.sessions});

  @override
  Widget build(BuildContext context) {
    final dayName = DateFormat('EEE').format(day).toUpperCase();
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: KsColors.border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                children: [
                  Text(dayName,
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: isToday ? KsColors.primary : KsColors.ink4,
                          letterSpacing: 0.4)),
                  const SizedBox(height: 2),
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isToday ? KsColors.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Text(day.day.toString(),
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: isToday ? Colors.white : KsColors.ink2)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: sessions.isEmpty
                  ? Text('No sessions',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: KsColors.ink4))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < sessions.length; i++) ...[
                          if (i > 0) const SizedBox(height: 6),
                          _WeekSessionChip(s: sessions[i]),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekSessionChip extends StatelessWidget {
  final Map<String, dynamic> s;
  const _WeekSessionChip({required this.s});

  @override
  Widget build(BuildContext context) {
    final code = (s['courseCode'] ?? '').toString();
    final hex = (s['courseAccentColour'] ?? '').toString();
    final colour = courseColour(code, hex);
    final id = (s['sessionId'] ?? s['id'] ?? '').toString();
    final start = DateTime.tryParse(s['startsAt'] ?? '')?.toLocal();
    final tf = DateFormat('HH:mm');
    final location = (s['locationName'] ?? '').toString();
    final students = ((s['students'] as List?) ?? const []).length;
    final activeBookings = (s['activeBookings'] ?? students) as int;
    return InkWell(
      onTap: () => context.push('/instructor/session/$id'),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: colour, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$code${start != null ? ' · ${tf.format(start)}' : ''}',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: KsColors.ink)),
            const SizedBox(height: 1),
            Text([
              if (location.isNotEmpty) location,
              '$activeBookings student${activeBookings == 1 ? '' : 's'}',
            ].join(' · '),
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: KsColors.ink3)),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final ScheduleMode mode;
  const _EmptyState({required this.mode});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 32, 8, 24),
      child: Column(
        children: [
          const Icon(Icons.event_busy_outlined, size: 56, color: KsColors.ink4),
          const SizedBox(height: 12),
          Text(
              mode == ScheduleMode.day
                  ? 'No sessions on this day'
                  : 'Quiet week',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: KsColors.ink)),
          const SizedBox(height: 4),
          const Text('Pull to refresh.',
              style: TextStyle(color: KsColors.ink2)),
        ],
      ),
    );
  }
}
