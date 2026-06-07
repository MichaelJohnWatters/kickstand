// Instructor schedule — Day / Week toggle. Uses GET /calendar (auto-scoped
// to the caller's own sessions for instructors). Tapping a session card
// opens session detail.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/notification_bell.dart';

enum ScheduleMode { day, week }

/// (mode, dayOffset). dayOffset is days from today; week mode uses the
/// monday-of containing today + offset*7.
final scheduleModeProvider = StateProvider<ScheduleMode>((_) => ScheduleMode.day);
final scheduleOffsetProvider = StateProvider<int>((_) => 0);

final scheduleSessionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final api = ref.read(apiClientProvider);
  final mode = ref.watch(scheduleModeProvider);
  final offset = ref.watch(scheduleOffsetProvider);
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
  return api.calendar(from: from, to: to);
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
      appBar: AppBar(
        title: Text(_headerTitle(mode, offset),
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: const [NotificationBell()],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(54),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                _ModeSwitch(),
                const Spacer(),
                IconButton(
                  onPressed: () => ref.read(scheduleOffsetProvider.notifier).state = offset - 1,
                  icon: const Icon(Icons.chevron_left, color: KsColors.ink2),
                ),
                TextButton(
                  onPressed: () => ref.read(scheduleOffsetProvider.notifier).state = 0,
                  child: const Text('Today'),
                ),
                IconButton(
                  onPressed: () => ref.read(scheduleOffsetProvider.notifier).state = offset + 1,
                  icon: const Icon(Icons.chevron_right, color: KsColors.ink2),
                ),
              ],
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        color: KsColors.primary,
        onRefresh: () async => ref.invalidate(scheduleSessionsProvider),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator(color: KsColors.primary)),
          error: (e, _) => ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('Couldn’t load.\n$e'))]),
          data: (sessions) {
            // Filter to my own sessions (server already does it for
            // instructors but belt-and-braces in case of role drift).
            final mine = auth.identity?.userId ?? '';
            final list = sessions.where((s) => (s['instructorId'] ?? '') == mine).toList();
            if (list.isEmpty) {
              return ListView(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 64, 32, 24),
                  child: Column(children: [
                    const Icon(Icons.event_busy_outlined, size: 56, color: KsColors.ink4),
                    const SizedBox(height: 12),
                    Text(mode == ScheduleMode.day ? 'No sessions on this day' : 'Quiet week',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 16, fontWeight: FontWeight.w700, color: KsColors.ink)),
                    const SizedBox(height: 4),
                    const Text('Pull to refresh.', style: TextStyle(color: KsColors.ink2)),
                  ]),
                ),
              ]);
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (ctx, i) => _SessionCard(list[i]),
            );
          },
        ),
      ),
    );
  }

  String _headerTitle(ScheduleMode mode, int offset) {
    final now = DateTime.now();
    if (mode == ScheduleMode.day) {
      final base = DateTime(now.year, now.month, now.day).add(Duration(days: offset));
      if (offset == 0) return 'Today';
      if (offset == 1) return 'Tomorrow';
      return DateFormat('EEE d MMM').format(base);
    }
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    final from = monday.add(Duration(days: offset * 7));
    return offset == 0 ? 'This week' : 'Week of ${DateFormat('d MMM').format(from)}';
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
      padding: const EdgeInsets.all(3),
      child: Row(children: [
        _opt(ref, ScheduleMode.day, mode, 'Day'),
        _opt(ref, ScheduleMode.week, mode, 'Week'),
      ]),
    );
  }

  Widget _opt(WidgetRef ref, ScheduleMode value, ScheduleMode current, String label) {
    final active = value == current;
    return GestureDetector(
      onTap: () => ref.read(scheduleModeProvider.notifier).state = value,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? KsColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(KsRadius.pill),
        ),
        child: Text(label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: active ? KsColors.ink : KsColors.ink3,
              fontSize: 13,
            )),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final Map<String, dynamic> s;
  const _SessionCard(this.s);

  @override
  Widget build(BuildContext context) {
    final startsAt = DateTime.tryParse(s['startsAt'] ?? '')?.toLocal();
    final endsAt = DateTime.tryParse(s['endsAt'] ?? '')?.toLocal();
    final tf = DateFormat('HH:mm');
    final df = DateFormat('EEE d MMM');
    final active = s['activeBookings'] ?? 0;
    final capacity = s['capacity'] ?? 0;
    final nonTeaching = s['nonTeaching'] ?? false;

    return InkWell(
      onTap: () => context.push('/instructor/session/${s['sessionId']}'),
      borderRadius: BorderRadius.circular(KsRadius.lg),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: KsColors.border),
          boxShadow: KsShadows.sh1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(s['courseName'] ?? '',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 16, fontWeight: FontWeight.w700, color: KsColors.ink, letterSpacing: -0.3)),
                ),
                if (nonTeaching)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: KsColors.warningTint,
                      borderRadius: BorderRadius.circular(KsRadius.pill),
                    ),
                    child: const Text('Test day',
                        style: TextStyle(color: KsColors.warning, fontWeight: FontWeight.w700, fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (startsAt != null && endsAt != null)
              _row(Icons.schedule, '${df.format(startsAt)} · ${tf.format(startsAt)}–${tf.format(endsAt)}'),
            _row(Icons.place_outlined, s['locationName'] ?? ''),
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.people_outline, size: 16, color: KsColors.ink3),
              const SizedBox(width: 6),
              Text('$active / $capacity students',
                  style: const TextStyle(color: KsColors.ink2, fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              const Icon(Icons.chevron_right, color: KsColors.ink3),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Icon(icon, size: 16, color: KsColors.ink3),
            const SizedBox(width: 6),
            Expanded(
              child: Text(text,
                  style: const TextStyle(fontSize: 13, color: KsColors.ink2),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
}
