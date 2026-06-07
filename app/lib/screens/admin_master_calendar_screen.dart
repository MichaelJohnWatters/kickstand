// Admin Master Calendar — week timeline.
//
// Layout:
//   - Header: week navigation + filters (location)
//   - Travel-warnings banner (expandable list) when /calendar returns any
//   - Grid: time axis (left) + 7 day columns with positioned session blocks
//
// Sessions are coloured by course-type code (hash → palette) and stacked
// into lanes within a day-column when they overlap. Click a block → drawer
// with session detail; tap "Open session" to navigate to instructor screens.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../state/providers.dart';
import '../theme/tokens.dart';

// ----- Tunables -----

const _calendarStartHour = 8; // 08:00
const _calendarEndHour = 18;  // 18:00 (rendered as the last gridline at this hour)
const _timeAxisWidth = 56.0;

// Grid pixels-per-minute is computed at layout-time so the whole week
// fits the viewport — see _Grid below. These are just the min / fallback
// densities so blocks stay legible on very small screens (we'll scroll
// then) and don't become absurdly tall on big monitors.
const _minPxPerMinute = 0.7;
const _maxPxPerMinute = 1.5;

// Pre-set palette to colour-code course codes deterministically.
const _coursePalette = [
  Color(0xFF6366F1), // indigo (primary)
  Color(0xFF1F9D6B), // green
  Color(0xFFC98A1E), // amber
  Color(0xFF9333EA), // purple
  Color(0xFF0EA5E9), // sky
  Color(0xFFEC4899), // pink
];
/// Prefers the school-configured hex colour. Falls back to a stable
/// palette index hashed from the course code so older sessions or
/// schools that haven't picked a colour still render distinctly.
Color _colourForCode(String code, [String hex = '']) {
  var s = hex.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) {
    final n = int.tryParse(s, radix: 16);
    if (n != null) return Color(0xFF000000 | n);
  }
  if (code.isEmpty) return _coursePalette[0];
  var h = 0;
  for (final r in code.runes) {
    h = (h * 31 + r) & 0x7fffffff;
  }
  return _coursePalette[h % _coursePalette.length];
}

// ----- State -----

/// View modes the manager can pick. `day` and `threeDays` anchor on
/// "today" by default; `week` snaps to the visible week's Monday;
/// `month` snaps to the first of the visible month.
enum CalendarView { day, threeDays, week, month }

int _daysInView(CalendarView v) {
  switch (v) {
    case CalendarView.day:
      return 1;
    case CalendarView.threeDays:
      return 3;
    case CalendarView.week:
      return 7;
    case CalendarView.month:
      // Used to size the API range. The actual month renderer derives
      // length from the anchor month itself so 28/29/30/31 days are honest.
      return 31;
  }
}

DateTime _mondayOf(DateTime d) =>
    DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));

DateTime _firstOfMonth(DateTime d) => DateTime(d.year, d.month, 1);

DateTime _defaultAnchor(DateTime now, CalendarView view) {
  switch (view) {
    case CalendarView.day:
    case CalendarView.threeDays:
      return DateTime(now.year, now.month, now.day);
    case CalendarView.week:
      // Hop to next Monday on Sat/Sun so the demo opens to a week with
      // sessions in it instead of trailing behind today.
      if (now.weekday >= DateTime.saturday) {
        return _mondayOf(now.add(const Duration(days: 3)));
      }
      return _mondayOf(now);
    case CalendarView.month:
      return _firstOfMonth(now);
  }
}

final _viewModeProvider =
    StateProvider.autoDispose<CalendarView>((_) => CalendarView.week);

/// Anchor date for the view (left-most day rendered). Defaults to today's
/// natural anchor for the default view. When the user switches view mode,
/// the picker also re-snaps the anchor.
final _anchorDateProvider = StateProvider.autoDispose<DateTime>(
    (_) => _defaultAnchor(DateTime.now(), CalendarView.week));

final _locationFilterProvider = StateProvider.autoDispose<String?>((_) => null);
final _courseFilterProvider = StateProvider.autoDispose<String?>((_) => null);

// `masterCalendarProvider` is intentionally NOT autoDispose so the ambient
// refresh observer (state/refresh.dart) can invalidate it on its timer —
// once invalidated it keeps the cached value painted while the new future
// runs, so the calendar grid never flashes. Filter state lives in the
// screen-local StateProviders above and feeds in via ref.watch.
final masterCalendarProvider =
    FutureProvider<_CalendarPayload>((ref) async {
  final api = ref.read(apiClientProvider);
  final view = ref.watch(_viewModeProvider);
  final from = ref.watch(_anchorDateProvider);
  final to = from.add(Duration(days: _daysInView(view)));
  final locationId = ref.watch(_locationFilterProvider);
  final courseTypeId = ref.watch(_courseFilterProvider);
  final body = await api.calendarFull(
      from: from, to: to, locationId: locationId, courseTypeId: courseTypeId);
  return _CalendarPayload(
    sessions: ((body['sessions'] as List?) ?? const []).cast<Map<String, dynamic>>(),
    warnings: ((body['warnings'] as List?) ?? const []).cast<Map<String, dynamic>>(),
  );
});

class _CalendarPayload {
  final List<Map<String, dynamic>> sessions;
  final List<Map<String, dynamic>> warnings;
  _CalendarPayload({required this.sessions, required this.warnings});
}

class AdminMasterCalendarScreen extends ConsumerWidget {
  const AdminMasterCalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(_viewModeProvider);
    final anchor = ref.watch(_anchorDateProvider);
    final async = ref.watch(masterCalendarProvider);

    return Scaffold(
      backgroundColor: KsColors.bg,
      body: Column(
        children: [
          const _Header(),
          async.when(
            data: (payload) => payload.warnings.isEmpty
                ? const SizedBox.shrink()
                : _WarningsBanner(warnings: payload.warnings),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator(color: KsColors.primary)),
              error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Couldn’t load.\n$e'))),
              data: (payload) => view == CalendarView.month
                  ? _MonthList(anchor: anchor, sessions: payload.sessions)
                  : _Grid(
                      anchor: anchor,
                      days: _daysInView(view),
                      sessions: payload.sessions),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(_viewModeProvider);
    final anchor = ref.watch(_anchorDateProvider);
    final days = _daysInView(view);
    final end = anchor.add(Duration(days: days - 1));

    String rangeStr;
    switch (view) {
      case CalendarView.day:
        rangeStr = DateFormat('EEEE d MMMM').format(anchor);
        break;
      case CalendarView.threeDays:
        rangeStr =
            '${DateFormat('d MMM').format(anchor)} – ${DateFormat('d MMM yyyy').format(end)}';
        break;
      case CalendarView.week:
        rangeStr =
            '${DateFormat('d MMM').format(anchor)} – ${DateFormat('d MMM yyyy').format(end)}';
        break;
      case CalendarView.month:
        rangeStr = DateFormat('MMMM yyyy').format(anchor);
        break;
    }

    void step(int direction) {
      DateTime next;
      switch (view) {
        case CalendarView.day:
          next = anchor.add(Duration(days: direction));
          break;
        case CalendarView.threeDays:
          next = anchor.add(Duration(days: 3 * direction));
          break;
        case CalendarView.week:
          next = anchor.add(Duration(days: 7 * direction));
          break;
        case CalendarView.month:
          next = DateTime(anchor.year, anchor.month + direction, 1);
          break;
      }
      ref.read(_anchorDateProvider.notifier).state = next;
    }

    void jumpToNow() {
      ref.read(_anchorDateProvider.notifier).state =
          _defaultAnchor(DateTime.now(), view);
    }

    final nowLabel = switch (view) {
      CalendarView.day => 'Today',
      CalendarView.threeDays => 'Today',
      CalendarView.week => 'This week',
      CalendarView.month => 'This month',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Title (left) + Prev/Now/Next (right).
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text('Master calendar',
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink,
                        letterSpacing: -0.6)),
              ),
              const SizedBox(width: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => step(-1),
                    icon: const Icon(Icons.chevron_left, size: 16),
                    label: const Text('Prev'),
                  ),
                  TextButton(onPressed: jumpToNow, child: Text(nowLabel)),
                  OutlinedButton.icon(
                    onPressed: () => step(1),
                    icon: const Icon(Icons.chevron_right, size: 16),
                    label: const Text('Next'),
                  ),
                  // Date picker for jumping anywhere. We snap the picked
                  // date into the view's natural anchor (Monday for week,
                  // 1st for month, picked date for day / 3-day).
                  OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today_rounded, size: 14),
                    label: const Text('Jump to…'),
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: anchor,
                        firstDate: DateTime(now.year - 1),
                        lastDate: DateTime(now.year + 2),
                      );
                      if (picked == null) return;
                      DateTime snapped;
                      switch (view) {
                        case CalendarView.day:
                        case CalendarView.threeDays:
                          snapped =
                              DateTime(picked.year, picked.month, picked.day);
                          break;
                        case CalendarView.week:
                          snapped = _mondayOf(picked);
                          break;
                        case CalendarView.month:
                          snapped = _firstOfMonth(picked);
                          break;
                      }
                      ref.read(_anchorDateProvider.notifier).state = snapped;
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Row 2: subtitle / range string.
          Text('All instructors, bikes & bookings · $rangeStr',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: KsColors.ink3, fontSize: 13)),
          const SizedBox(height: 12),
          // Row 3: filter pills + view-mode picker, left-aligned.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: const [
              _ViewPicker(),
              _SitePicker(),
              _CoursePicker(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Day / 3 days / Week / Month picker. Switching also re-snaps the anchor
/// to the closest-natural-now for the new view, so e.g. flipping from
/// Day → Week lands you on this Monday rather than "the Monday before
/// today" (which would feel like the calendar drifted backwards).
class _ViewPicker extends ConsumerWidget {
  const _ViewPicker();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(_viewModeProvider);
    final items = <(CalendarView, String)>[
      (CalendarView.day, 'Day'),
      (CalendarView.threeDays, '3 days'),
      (CalendarView.week, 'Week'),
      (CalendarView.month, 'Month'),
    ];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: KsColors.surface2,
        borderRadius: BorderRadius.circular(KsRadius.md),
        border: Border.all(color: KsColors.border),
      ),
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        children: items.map((it) {
          final on = selected == it.$1;
          return InkWell(
            onTap: () {
              ref.read(_viewModeProvider.notifier).state = it.$1;
              ref.read(_anchorDateProvider.notifier).state =
                  _defaultAnchor(DateTime.now(), it.$1);
            },
            borderRadius: BorderRadius.circular(KsRadius.pill),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: on ? KsColors.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(KsRadius.pill),
                boxShadow: on ? KsShadows.sh1 : null,
              ),
              child: Text(it.$2,
                  style: GoogleFonts.plusJakartaSans(
                      color: on ? KsColors.ink : KsColors.ink3,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5)),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Site picker pill — sits inline in the calendar header. Async-loaded
/// because the location list comes from the API; while loading we just
/// render the placeholder so the header doesn't reflow.
class _SitePicker extends ConsumerWidget {
  const _SitePicker();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = ref.watch(_locationFilterProvider);
    // Re-use the shared locationsProvider so a rename / add in the
    // locations editor reflects here too (handled by refreshAdminTab).
    final locsAsync = ref.watch(locationsProvider);
    return locsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (locs) {
        final items = <_PickerItem>[
          const _PickerItem(value: '', label: 'All sites'),
          for (final l in locs) _PickerItem(value: l.id, label: l.name),
        ];
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: KsColors.surface2,
            borderRadius: BorderRadius.circular(KsRadius.md),
            border: Border.all(color: KsColors.border),
          ),
          child: Wrap(
            spacing: 2,
            runSpacing: 2,
            children: items.map((it) {
              final selected = (loc ?? '') == it.value;
              return InkWell(
                onTap: () =>
                    ref.read(_locationFilterProvider.notifier).state =
                        it.value.isEmpty ? null : it.value,
                borderRadius: BorderRadius.circular(KsRadius.pill),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected ? KsColors.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                    boxShadow: selected ? KsShadows.sh1 : null,
                  ),
                  child: Text(it.label,
                      style: GoogleFonts.plusJakartaSans(
                          color: selected ? KsColors.ink : KsColors.ink3,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5)),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

class _PickerItem {
  final String value;
  final String label;
  const _PickerItem({required this.value, required this.label});
}

/// Course-type picker pill — same shape as `_SitePicker`. Populated from
/// the shared `courseTypesProvider` so editing course types in the admin
/// elsewhere is reflected here on the next tab visit.
class _CoursePicker extends ConsumerWidget {
  const _CoursePicker();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(_courseFilterProvider);
    final coursesAsync = ref.watch(courseTypesProvider);
    return coursesAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (courses) {
        if (courses.isEmpty) return const SizedBox.shrink();
        final items = <_PickerItem>[
          const _PickerItem(value: '', label: 'All courses'),
          for (final c in courses)
            _PickerItem(value: c.id, label: c.code.isEmpty ? c.name : c.code),
        ];
        // Wrap (not Row) so the pills break to a second line when the
        // school has many course types. The outer container uses a smaller
        // radius — a pill shape looks weird stretched over two rows.
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: KsColors.surface2,
            borderRadius: BorderRadius.circular(KsRadius.md),
            border: Border.all(color: KsColors.border),
          ),
          child: Wrap(
            spacing: 2,
            runSpacing: 2,
            children: items.map((it) {
              final on = (selected ?? '') == it.value;
              return InkWell(
                onTap: () => ref.read(_courseFilterProvider.notifier).state =
                    it.value.isEmpty ? null : it.value,
                borderRadius: BorderRadius.circular(KsRadius.pill),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: on ? KsColors.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                    boxShadow: on ? KsShadows.sh1 : null,
                  ),
                  child: Text(it.label,
                      style: GoogleFonts.plusJakartaSans(
                          color: on ? KsColors.ink : KsColors.ink3,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5)),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

// _FilterBar removed — site picker now lives inline in _Header.

// ----- Warnings banner -----

class _WarningsBanner extends StatelessWidget {
  final List<Map<String, dynamic>> warnings;
  const _WarningsBanner({required this.warnings});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final w in warnings) ...[
            _TravelWarningRow(w: w),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// One travel-warning row — matches the design's `Tight travel: …` banner.
/// Renders the full prose from the backend payload plus a "Non-blocking"
/// chip so the manager knows they don't have to act.
class _TravelWarningRow extends StatelessWidget {
  final Map<String, dynamic> w;
  const _TravelWarningRow({required this.w});

  @override
  Widget build(BuildContext context) {
    final tf = DateFormat('HH:mm');
    final from = (w['fromLocationName'] ?? '').toString();
    final to = (w['toLocationName'] ?? '').toString();
    final fromEnds = DateTime.tryParse((w['fromEndsAt'] ?? '').toString())?.toLocal();
    final toStarts = DateTime.tryParse((w['toStartsAt'] ?? '').toString())?.toLocal();
    final gap = (w['gapMinutes'] as num?)?.toInt() ?? 0;
    final travel = (w['travelMinutes'] as num?)?.toInt() ?? 0;
    final buffer = (w['bufferMinutes'] as num?)?.toInt() ?? 0;
    final instructor = (w['instructorName'] ?? '').toString();
    final fromTime = fromEnds == null ? '' : tf.format(fromEnds);
    final toTime = toStarts == null ? '' : tf.format(toStarts);

    return Container(
      decoration: BoxDecoration(
        color: KsColors.warningTint,
        borderRadius: BorderRadius.circular(KsRadius.md),
        border: Border.all(color: KsColors.warning.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.route_outlined, color: KsColors.warning, size: 19),
          const SizedBox(width: 11),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: GoogleFonts.plusJakartaSans(
                    color: KsColors.ink2,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.4),
                children: [
                  TextSpan(
                      text: 'Tight travel: ',
                      style: GoogleFonts.plusJakartaSans(
                          color: KsColors.warning,
                          fontWeight: FontWeight.w800,
                          fontSize: 13)),
                  TextSpan(
                      text: instructor,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  const TextSpan(text: ' — '),
                  TextSpan(text: '$from $fromTime → $to $toTime'),
                  TextSpan(text: ' leaves $gap min, but it’s ~$travel min '
                      '+ $buffer buffer. Worth a check.'),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: KsColors.warning,
              borderRadius: BorderRadius.circular(KsRadius.pill),
            ),
            child: Text('Non-blocking',
                style: GoogleFonts.plusJakartaSans(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 10.5)),
          ),
        ],
      ),
    );
  }
}

// ----- Grid -----

class _Grid extends StatelessWidget {
  final DateTime anchor;
  final int days;
  final List<Map<String, dynamic>> sessions;
  const _Grid({
    required this.anchor,
    required this.days,
    required this.sessions,
  });

  @override
  Widget build(BuildContext context) {
    // Bucket sessions by day offset from anchor (0..days-1).
    final byDay = <int, List<Map<String, dynamic>>>{for (var i = 0; i < days; i++) i: []};
    for (final s in sessions) {
      final startsAt = DateTime.tryParse(s['startsAt'] ?? '')?.toLocal();
      if (startsAt == null) continue;
      final dayDiff = DateTime(startsAt.year, startsAt.month, startsAt.day)
          .difference(anchor)
          .inDays;
      if (dayDiff < 0 || dayDiff >= days) continue;
      byDay[dayDiff]!.add(s);
    }
    for (final list in byDay.values) {
      list.sort((a, b) => (a['startsAt'] ?? '').toString().compareTo((b['startsAt'] ?? '').toString()));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: LayoutBuilder(builder: (ctx, c) {
        final totalMinutes = (_calendarEndHour - _calendarStartHour) * 60;
        // Reserve room for the day headers (~48px) and the legend row
        // below (~28px) plus the card's own border and shadow.
        const reservedChrome = 48.0 + 28.0 + 14.0;
        final availableForGrid = (c.maxHeight - reservedChrome).clamp(280.0, 1200.0);
        // Density that fills the available height, clamped so blocks
        // stay readable and don't bloat absurdly.
        final pxPerMinute = (availableForGrid / totalMinutes)
            .clamp(_minPxPerMinute, _maxPxPerMinute);
        final gridHeight = totalMinutes * pxPerMinute;
        // If the natural grid would still overflow at min density, allow
        // vertical scrolling within the card; otherwise size to fit.
        final needsScroll = gridHeight > availableForGrid + 0.5;

        Widget gridBody = SizedBox(
          height: gridHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _timeAxisWidth,
                child: _TimeAxis(
                    totalHeight: gridHeight, pxPerMinute: pxPerMinute),
              ),
              Expanded(
                child: Row(
                  children: List.generate(days, (day) {
                    final dayDate = anchor.add(Duration(days: day));
                    return Expanded(
                      child: Container(
                        decoration: const BoxDecoration(
                          border: Border(
                            left: BorderSide(color: KsColors.border),
                          ),
                        ),
                        child: _DayColumn(
                          date: dayDate,
                          sessions: byDay[day] ?? const [],
                          totalHeight: gridHeight,
                          pxPerMinute: pxPerMinute,
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        );

        if (needsScroll) {
          gridBody = SingleChildScrollView(child: gridBody);
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: KsColors.surface,
                  borderRadius: BorderRadius.circular(KsRadius.lg),
                  border: Border.all(color: KsColors.border),
                  boxShadow: KsShadows.sh1,
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _DayHeaders(anchor: anchor, days: days),
                    Expanded(child: gridBody),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            _CourseLegend(sessions: sessions),
          ],
        );
      }),
    );
  }
}

class _DayHeaders extends StatelessWidget {
  final DateTime anchor;
  final int days;
  const _DayHeaders({required this.anchor, required this.days});
  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    bool isToday(DateTime d) =>
        d.year == today.year && d.month == today.month && d.day == today.day;
    return Container(
      decoration: const BoxDecoration(
        color: KsColors.surface2,
        border: Border(bottom: BorderSide(color: KsColors.border)),
      ),
      child: Row(children: [
        SizedBox(width: _timeAxisWidth),
        ...List.generate(days, (i) {
          final d = anchor.add(Duration(days: i));
          final today_ = isToday(d);
          return Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: today_ ? KsColors.primaryTint : Colors.transparent,
                border: const Border(left: BorderSide(color: KsColors.border)),
              ),
              child: Column(
                children: [
                  Text(DateFormat('EEE').format(d).toUpperCase(),
                      style: TextStyle(
                          color: today_ ? KsColors.primaryDeep : KsColors.ink3,
                          fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 0.5)),
                  const SizedBox(height: 2),
                  Text('${d.day}',
                      style: GoogleFonts.plusJakartaSans(
                          color: today_ ? KsColors.primaryDeep : KsColors.ink,
                          fontWeight: FontWeight.w800, fontSize: 16)),
                ],
              ),
            ),
          );
        }),
      ]),
    );
  }
}

class _TimeAxis extends StatelessWidget {
  final double totalHeight;
  final double pxPerMinute;
  const _TimeAxis({required this.totalHeight, required this.pxPerMinute});
  @override
  Widget build(BuildContext context) {
    final hours = _calendarEndHour - _calendarStartHour;
    return SizedBox(
      height: totalHeight,
      child: Column(
        children: List.generate(hours, (i) {
          final hour = _calendarStartHour + i;
          return SizedBox(
            height: 60 * pxPerMinute,
            child: Padding(
              padding: const EdgeInsets.only(right: 6, top: 2),
              child: Align(
                alignment: Alignment.topRight,
                child: Text('${hour.toString().padLeft(2, '0')}:00',
                    style: const TextStyle(color: KsColors.ink3, fontSize: 10, fontWeight: FontWeight.w700)),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Course-colour legend strip below the grid — derived from whatever
/// course codes actually appear this week so it matches the rendered
/// blocks exactly.
class _CourseLegend extends StatelessWidget {
  final List<Map<String, dynamic>> sessions;
  const _CourseLegend({required this.sessions});

  @override
  Widget build(BuildContext context) {
    // (name, hex) per code so the legend swatch uses the school-set colour
    // when present, falling back to the hashed palette otherwise.
    final byCode = <String, (String, String)>{};
    for (final s in sessions) {
      final code = (s['courseCode'] ?? '').toString();
      final name = (s['courseName'] ?? '').toString();
      final hex = (s['courseAccentColour'] ?? '').toString();
      if (code.isEmpty) continue;
      byCode.putIfAbsent(code, () => (name, hex));
    }
    if (byCode.isEmpty) return const SizedBox.shrink();
    final codes = byCode.keys.toList()..sort();
    return Wrap(
      spacing: 18,
      runSpacing: 6,
      children: [
        for (final code in codes)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: _colourForCode(code, byCode[code]!.$2),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 7),
              Text(byCode[code]!.$1.isEmpty ? code : byCode[code]!.$1,
                  style: const TextStyle(
                      color: KsColors.ink2,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
            ],
          ),
      ],
    );
  }
}

class _DayColumn extends StatelessWidget {
  final DateTime date;
  final List<Map<String, dynamic>> sessions;
  final double totalHeight;
  final double pxPerMinute;
  const _DayColumn({
    required this.date,
    required this.sessions,
    required this.totalHeight,
    required this.pxPerMinute,
  });

  /// Assigns each session a (lane, lanesInCluster) pair so overlapping
  /// sessions share the column width without stacking on top of each other.
  ///
  /// Width + lane position are computed PER session, not per cluster: each
  /// session's `lanesInCluster` is the count of distinct lanes occupied by
  /// sessions actually overlapping it. So A (9–10) and C (11–13), both
  /// chained to B (9–12), get full width whenever they aren't competing
  /// with each other — only B has to shrink to 50%.
  List<_PositionedSession> _lay(BuildContext context) {
    final parsed = <({DateTime start, DateTime end, Map<String, dynamic> data})>[];
    for (final s in sessions) {
      final start = DateTime.tryParse(s['startsAt'] ?? '')?.toLocal();
      final end = DateTime.tryParse(s['endsAt'] ?? '')?.toLocal();
      if (start == null || end == null) continue;
      parsed.add((start: start, end: end, data: s));
    }

    // Pass 1: greedy lane assignment (left-most free lane wins).
    // ends[lane] = the next moment that lane becomes free.
    final laneEnds = <DateTime>[];
    final lanes = List<int>.filled(parsed.length, 0);
    for (var i = 0; i < parsed.length; i++) {
      final p = parsed[i];
      int lane = laneEnds.indexWhere((e) => !e.isAfter(p.start));
      if (lane == -1) {
        lane = laneEnds.length;
        laneEnds.add(p.end);
      } else {
        laneEnds[lane] = p.end;
      }
      lanes[i] = lane;
    }

    // Pass 2: for each session, the set of lanes used by sessions that
    // actually overlap it. Width = 1/size; position = rank within sorted
    // set of overlapping lanes (so the block hugs the side it was packed
    // into rather than floating in the middle).
    final out = <_PositionedSession>[];
    for (var i = 0; i < parsed.length; i++) {
      final p = parsed[i];
      final overlappingLanes = <int>{lanes[i]};
      for (var j = 0; j < parsed.length; j++) {
        if (i == j) continue;
        final q = parsed[j];
        // half-open overlap: q.start < p.end && q.end > p.start
        if (q.start.isBefore(p.end) && q.end.isAfter(p.start)) {
          overlappingLanes.add(lanes[j]);
        }
      }
      final sorted = overlappingLanes.toList()..sort();
      out.add(_PositionedSession(
        session: p.data,
        start: p.start,
        end: p.end,
        lane: sorted.indexOf(lanes[i]),
        lanesInCluster: sorted.length,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final positioned = _lay(context);
    final startMinutes = _calendarStartHour * 60;

    return SizedBox(
      height: totalHeight,
      child: Stack(
        children: [
          // Hour gridlines.
          ...List.generate(_calendarEndHour - _calendarStartHour, (i) {
            final y = i * 60 * pxPerMinute;
            return Positioned(
              left: 0, right: 0, top: y,
              child: Container(
                height: 1,
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: KsColors.border, width: 1)),
                ),
              ),
            );
          }),

          // Session blocks.
          ...positioned.map((ps) {
            final s = ps.session;
            final startMins = ps.start.hour * 60 + ps.start.minute - startMinutes;
            final durMins = ps.end.difference(ps.start).inMinutes;
            final top = (startMins.clamp(0, (_calendarEndHour - _calendarStartHour) * 60)) * pxPerMinute;
            final bottomCap = (_calendarEndHour - _calendarStartHour) * 60;
            final endCapped = (startMins + durMins).clamp(startMins, bottomCap);
            final height = ((endCapped - startMins).clamp(20, bottomCap)) * pxPerMinute;

            // Alignment maps lane → x in [-1, +1] so the first lane hugs
            // the left edge and the last lane hugs the right. Old formula
            // `-1 + 2*lane/lanes` centred the right-most lane (lane 1 of
            // 2 → 0, i.e. 25%–75%) instead of right-aligning it, which
            // left the right side of the column empty.
            final alignX = ps.lanesInCluster <= 1
                ? 0.0
                : -1 + (2.0 * ps.lane / (ps.lanesInCluster - 1));
            return Positioned(
              top: top,
              left: 0,
              right: 0,
              height: height.toDouble(),
              child: FractionallySizedBox(
                widthFactor: 1.0 / ps.lanesInCluster,
                alignment: Alignment(alignX, 0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                  child: _SessionBlock(session: s),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _PositionedSession {
  final Map<String, dynamic> session;
  final DateTime start;
  final DateTime end;
  final int lane;
  final int lanesInCluster;
  _PositionedSession({
    required this.session,
    required this.start,
    required this.end,
    required this.lane,
    required this.lanesInCluster,
  });
  _PositionedSession copyWith({int? lanesInCluster}) => _PositionedSession(
        session: session,
        start: start,
        end: end,
        lane: lane,
        lanesInCluster: lanesInCluster ?? this.lanesInCluster,
      );
}

class _SessionBlock extends StatelessWidget {
  final Map<String, dynamic> session;
  const _SessionBlock({required this.session});
  @override
  Widget build(BuildContext context) {
    final code = (session['courseCode'] ?? '').toString();
    final hex = (session['courseAccentColour'] ?? '').toString();
    final colour = _colourForCode(code, hex);
    final nonTeaching = session['nonTeaching'] ?? false;
    final startsAt = DateTime.tryParse(session['startsAt'] ?? '')?.toLocal();
    final endsAt = DateTime.tryParse(session['endsAt'] ?? '')?.toLocal();
    final tf = DateFormat('HH:mm');
    final timeStr =
        (startsAt == null || endsAt == null) ? '' : '${tf.format(startsAt)}–${tf.format(endsAt)}';
    return InkWell(
      onTap: () => showDialog(
        context: context,
        builder: (_) => _SessionDetailDialog(session: session),
      ),
      borderRadius: BorderRadius.circular(KsRadius.sm),
      child: Container(
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(KsRadius.sm),
          border: Border(left: BorderSide(color: colour, width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              session['courseName']?.toString() ?? '',
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: GoogleFonts.plusJakartaSans(
                color: colour.computeLuminance() > 0.5 ? KsColors.ink : KsColors.ink,
                fontWeight: FontWeight.w800, fontSize: 11, height: 1.2,
              ),
            ),
            if (timeStr.isNotEmpty)
              Text(timeStr,
                  style: const TextStyle(color: KsColors.ink2, fontSize: 10, fontWeight: FontWeight.w600)),
            Text(
              session['instructorName']?.toString() ?? '',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: KsColors.ink3, fontSize: 10),
            ),
            if (nonTeaching)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text('Test day',
                    style: TextStyle(color: KsColors.warning, fontSize: 9, fontWeight: FontWeight.w800)),
              ),
          ],
        ),
      ),
    );
  }
}

// ----- Session detail dialog -----

class _SessionDetailDialog extends StatelessWidget {
  final Map<String, dynamic> session;
  const _SessionDetailDialog({required this.session});

  @override
  Widget build(BuildContext context) {
    final startsAt = DateTime.tryParse(session['startsAt'] ?? '')?.toLocal();
    final endsAt = DateTime.tryParse(session['endsAt'] ?? '')?.toLocal();
    final df = DateFormat('EEE d MMM yyyy');
    final tf = DateFormat('HH:mm');
    final active = session['activeBookings'] ?? 0;
    final capacity = session['capacity'] ?? 0;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(session['courseName'] ?? '',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 19, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.4)),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: KsColors.ink3),
                ),
              ]),
              const SizedBox(height: 4),
              Text(session['courseCode'] ?? '',
                  style: const TextStyle(color: KsColors.ink3, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              if (startsAt != null && endsAt != null)
                _row(Icons.event, '${df.format(startsAt)} · ${tf.format(startsAt)}–${tf.format(endsAt)}'),
              _row(Icons.place_outlined, session['locationName'] ?? ''),
              _row(Icons.person_outline, session['instructorName'] ?? ''),
              _row(Icons.people_outline, '$active / $capacity students booked'),
              const SizedBox(height: 16),
              // Don't surface a session-detail navigation here because it
              // lives under /instructor/... which isn't reachable from admin
              // role. The admin can drill into students via the Students
              // screen; this dialog is informational.
              const Text(
                'Open the instructor portal to review attendance and competencies.',
                style: TextStyle(color: KsColors.ink3, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Icon(icon, color: KsColors.ink3, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(color: KsColors.ink2, fontSize: 13))),
        ]),
      );
}

/// Month view — 30 days of columns is unreadable, so we render each day
/// in the month as a section with its sessions listed below. Empty days
/// still show their date so the manager can scan for gaps.
class _MonthList extends StatelessWidget {
  final DateTime anchor; // first day of the month
  final List<Map<String, dynamic>> sessions;
  const _MonthList({required this.anchor, required this.sessions});

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(anchor.year, anchor.month + 1, 0).day;
    final byDay = <int, List<Map<String, dynamic>>>{
      for (var i = 0; i < daysInMonth; i++) i: []
    };
    for (final s in sessions) {
      final startsAt = DateTime.tryParse(s['startsAt'] ?? '')?.toLocal();
      if (startsAt == null) continue;
      if (startsAt.year != anchor.year || startsAt.month != anchor.month) continue;
      final idx = startsAt.day - 1;
      if (idx < 0 || idx >= daysInMonth) continue;
      byDay[idx]!.add(s);
    }
    for (final list in byDay.values) {
      list.sort((a, b) => (a['startsAt'] ?? '').toString().compareTo((b['startsAt'] ?? '').toString()));
    }
    final today = DateTime.now();
    final tFmt = DateFormat('HH:mm');

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Container(
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: KsColors.border),
          boxShadow: KsShadows.sh1,
        ),
        clipBehavior: Clip.antiAlias,
        child: ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: daysInMonth,
          itemBuilder: (ctx, i) {
            final date = DateTime(anchor.year, anchor.month, i + 1);
            final sessionsForDay = byDay[i] ?? const [];
            final isToday = date.year == today.year && date.month == today.month && date.day == today.day;
            return Container(
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: KsColors.border)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Date strip
                  Container(
                    width: 140,
                    padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                    decoration: BoxDecoration(
                      color: isToday ? KsColors.primaryTint : KsColors.surface2,
                      border: const Border(
                          right: BorderSide(color: KsColors.border)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(DateFormat('EEE').format(date).toUpperCase(),
                            style: TextStyle(
                                color: isToday
                                    ? KsColors.primaryDeep
                                    : KsColors.ink3,
                                fontWeight: FontWeight.w800,
                                fontSize: 11,
                                letterSpacing: 0.5)),
                        const SizedBox(height: 2),
                        Text('${date.day}',
                            style: GoogleFonts.plusJakartaSans(
                                color: isToday
                                    ? KsColors.primaryDeep
                                    : KsColors.ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 22)),
                        Text(DateFormat('MMM').format(date),
                            style: const TextStyle(
                                color: KsColors.ink3, fontSize: 12)),
                      ],
                    ),
                  ),
                  // Sessions list / empty state
                  Expanded(
                    child: Padding(
                      padding:
                          const EdgeInsets.fromLTRB(14, 10, 14, 10),
                      child: sessionsForDay.isEmpty
                          ? Text('—',
                              style: const TextStyle(
                                  color: KsColors.ink4, fontSize: 13))
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: sessionsForDay.map((s) {
                                final starts =
                                    DateTime.tryParse(s['startsAt'] ?? '')
                                        ?.toLocal();
                                final ends = DateTime.tryParse(
                                        s['endsAt'] ?? '')
                                    ?.toLocal();
                                final code =
                                    (s['courseTypeCode'] ?? '').toString();
                                final loc =
                                    (s['locationName'] ?? '').toString();
                                final instr =
                                    (s['instructorName'] ?? '').toString();
                                final hex = (s['courseAccentColour'] ?? '')
                                    .toString();
                                final accent = _colourForCode(code, hex);
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 4),
                                  child: Row(children: [
                                    Container(
                                      width: 4,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: accent,
                                        borderRadius:
                                            BorderRadius.circular(2),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    SizedBox(
                                      width: 90,
                                      child: Text(
                                          starts == null
                                              ? ''
                                              : '${tFmt.format(starts)}${ends == null ? '' : '–${tFmt.format(ends)}'}',
                                          style: GoogleFonts.spaceMono(
                                              color: KsColors.ink2,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 12)),
                                    ),
                                    Expanded(
                                      child: Text(
                                        '$code · $instr · $loc',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: KsColors.ink,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ]),
                                );
                              }).toList(),
                            ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
