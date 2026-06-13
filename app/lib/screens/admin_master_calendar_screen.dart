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

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';
import '../widgets/take_bike_offline_sheet.dart';

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

/// Multi-select mode for the manager's "rainy-day" bulk cancel
/// workflow. When on, tapping a session toggles its inclusion in the
/// selection set instead of opening the detail dialog. Both providers
/// reset on screen disposal so the next visit starts clean.
/// Master calendar's "Show cancelled" toggle. Off by default — the
/// engine drops cancelled sessions and cancelled bookings from the
/// payload so the page is lean; flip on for audit/review.
final _showCancelledProvider = StateProvider.autoDispose<bool>((_) => false);

final _bulkSelectModeProvider = StateProvider.autoDispose<bool>((_) => false);
final _bulkSelectionProvider =
    StateProvider.autoDispose<Set<String>>((_) => <String>{});

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
  final includeCancelled = ref.watch(_showCancelledProvider);
  final body = await api.calendarFull(
      from: from,
      to: to,
      locationId: locationId,
      courseTypeId: courseTypeId,
      includeCancelled: includeCancelled);
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

    final selectMode = ref.watch(_bulkSelectModeProvider);
    final selection = ref.watch(_bulkSelectionProvider);
    return Scaffold(
      backgroundColor: KsColors.bg,
      body: Stack(children: [
        Column(
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
                error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(24), child: KsEmptyState.error(message: e.toString()))),
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
        if (selectMode && selection.isNotEmpty)
          const Positioned(
            left: 0, right: 0, bottom: 0,
            child: _BulkActionBar(),
          ),
      ]),
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
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add session'),
                    onPressed: () => _showAddSessionSheet(context, ref, anchor),
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
          // Row 3: filter pills + view-mode picker + select toggle.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: const [
              _ViewPicker(),
              _SitePicker(),
              _CoursePicker(),
              _ShowCancelledToggle(),
              _SelectModeToggle(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Toggles bulk-select mode. Off → tapping a session opens detail;
/// on → tapping toggles inclusion in the cancel set. Distinct
/// affordance from a normal chip — gets a checklist icon and
/// flips to filled-style when active.
class _SelectModeToggle extends ConsumerWidget {
  const _SelectModeToggle();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(_bulkSelectModeProvider);
    final selection = ref.watch(_bulkSelectionProvider);
    return Tooltip(
      message: on
          ? 'Tap blocks to add/remove from selection. The bar at the bottom acts on all chosen sessions.'
          : 'Turn on to multi-select sessions for bulk actions (cancel many at once).',
      waitDuration: const Duration(milliseconds: 300),
      child: InkWell(
        onTap: () {
          final next = !on;
          ref.read(_bulkSelectModeProvider.notifier).state = next;
          if (!next) {
            ref.read(_bulkSelectionProvider.notifier).state = const {};
          }
        },
        borderRadius: BorderRadius.circular(KsRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: on ? KsColors.primary : KsColors.surface,
            borderRadius: BorderRadius.circular(KsRadius.pill),
            border: Border.all(
                color: on ? KsColors.primary : KsColors.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? Icons.check_box : Icons.checklist_rounded,
                size: 14,
                color: on ? Colors.white : KsColors.ink2),
            const SizedBox(width: 6),
            Text(
                on
                    ? (selection.isEmpty
                        ? 'Tap sessions…'
                        : '${selection.length} selected')
                    : 'Multi-select',
                style: GoogleFonts.plusJakartaSans(
                    color: on ? Colors.white : KsColors.ink2,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5)),
          ]),
        ),
      ),
    );
  }
}

/// Pill toggle for "Show cancelled" — when on, cancelled sessions and
/// cancelled bookings reappear on the calendar (faded + struck through)
/// so the manager can audit / review. Off by default keeps the page
/// lean.
class _ShowCancelledToggle extends ConsumerWidget {
  const _ShowCancelledToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(_showCancelledProvider);
    return Tooltip(
      message: on
          ? 'Cancelled sessions + bookings are visible (faded, struck through). Tap to hide.'
          : 'Include cancelled sessions and bookings on the calendar.',
      waitDuration: const Duration(milliseconds: 300),
      child: InkWell(
        onTap: () =>
            ref.read(_showCancelledProvider.notifier).state = !on,
        borderRadius: BorderRadius.circular(KsRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: on ? KsColors.dangerTint : KsColors.surface,
            borderRadius: BorderRadius.circular(KsRadius.pill),
            border: Border.all(
                color: on ? KsColors.danger.withValues(alpha: 0.45) : KsColors.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? Icons.visibility : Icons.visibility_off,
                size: 14,
                color: on ? KsColors.danger : KsColors.ink2),
            const SizedBox(width: 6),
            Text('Show cancelled',
                style: GoogleFonts.plusJakartaSans(
                    color: on ? KsColors.danger : KsColors.ink2,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5)),
          ]),
        ),
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
        // Each pill carries its course accent colour as a 8px dot so
        // the filter row matches the session-block colour-coding on
        // the calendar — picking a course visually maps back to its
        // blocks.
        final items = <(_PickerItem, Color?)>[
          (const _PickerItem(value: '', label: 'All courses'), null),
          for (final c in courses)
            (
              _PickerItem(value: c.id, label: c.code.isEmpty ? c.name : c.code),
              _colourForCode(c.code, c.accentColour),
            ),
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
            children: items.map((entry) {
              final it = entry.$1;
              final dotColour = entry.$2;
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
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (dotColour != null) ...[
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: dotColour,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(it.label,
                        style: GoogleFonts.plusJakartaSans(
                            color: on ? KsColors.ink : KsColors.ink3,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5)),
                  ]),
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

/// Tight-travel warnings — collapsible. Default state is a single
/// summary chip ("⚠️ N tight-travel warnings") so the calendar gets
/// the full page; tap to expand and see each row. State is local to
/// the widget so re-renders don't fold it back up.
class _WarningsBanner extends StatefulWidget {
  final List<Map<String, dynamic>> warnings;
  const _WarningsBanner({required this.warnings});

  @override
  State<_WarningsBanner> createState() => _WarningsBannerState();
}

class _WarningsBannerState extends State<_WarningsBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.warnings.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(KsRadius.md),
            child: Container(
              decoration: BoxDecoration(
                color: KsColors.warningTint,
                borderRadius: BorderRadius.circular(KsRadius.md),
                border: Border.all(
                    color: KsColors.warning.withValues(alpha: 0.35)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(children: [
                const Icon(Icons.route_outlined,
                    color: KsColors.warning, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: GoogleFonts.plusJakartaSans(
                          color: KsColors.ink2,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                      children: [
                        TextSpan(
                            text: '$n tight-travel warning${n == 1 ? '' : 's'}',
                            style: GoogleFonts.plusJakartaSans(
                                color: KsColors.warning,
                                fontWeight: FontWeight.w800,
                                fontSize: 13)),
                        TextSpan(
                            text: _expanded
                                ? ' — tap to hide'
                                : ' — tap to view',
                            style: const TextStyle(color: KsColors.ink3)),
                      ],
                    ),
                  ),
                ),
                Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: KsColors.ink3,
                    size: 20),
              ]),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 8),
            for (final w in widget.warnings) ...[
              _TravelWarningRow(w: w),
              const SizedBox(height: 8),
            ],
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

class _DayColumn extends ConsumerStatefulWidget {
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

  @override
  ConsumerState<_DayColumn> createState() => _DayColumnState();
}

class _DayColumnState extends ConsumerState<_DayColumn> {
  final _gridKey = GlobalKey();
  bool _dropActive = false;

  DateTime _dropTime(Offset globalOffset) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      // Fall back to noon of the dropped-on day — never lose the drop.
      return DateTime(widget.date.year, widget.date.month, widget.date.day, 12);
    }
    final local = box.globalToLocal(globalOffset);
    final minutesFromStart = (local.dy / widget.pxPerMinute).round();
    // Snap to the nearest 15 minutes — managers think in quarter-hours.
    final snapped = (minutesFromStart / 15).round() * 15;
    final maxMins = (_calendarEndHour - _calendarStartHour) * 60 - 15;
    final clamped = snapped.clamp(0, maxMins);
    final totalMins = _calendarStartHour * 60 + clamped;
    return DateTime(
      widget.date.year,
      widget.date.month,
      widget.date.day,
      totalMins ~/ 60,
      totalMins % 60,
    );
  }

  Future<void> _handleDrop(Map<String, dynamic> session, Offset globalOffset) async {
    final id = (session['sessionId'] ?? session['id'] ?? '').toString();
    if (id.isEmpty) return;
    final originalStart =
        DateTime.tryParse(session['startsAt'] ?? '')?.toLocal();
    final originalEnd =
        DateTime.tryParse(session['endsAt'] ?? '')?.toLocal();
    if (originalStart == null || originalEnd == null) return;
    final duration = originalEnd.difference(originalStart);
    final newStart = _dropTime(globalOffset);
    // Bail out if the user dropped it back on its current slot — no
    // sense burning an API call + audit row to move a session zero
    // minutes.
    if (newStart == originalStart) return;
    final newEnd = newStart.add(duration);

    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(apiClientProvider).updateSessionTime(
            sessionId: id,
            startsAt: newStart,
            endsAt: newEnd,
          );
      ref.invalidate(masterCalendarProvider);
      messenger?.showSnackBar(SnackBar(
        content: Text(
            'Moved to ${DateFormat('EEE d MMM HH:mm').format(newStart)}'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(
        content: Text('Could not move session: $e'),
        backgroundColor: KsColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

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
    for (final s in widget.sessions) {
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
    final pxPerMinute = widget.pxPerMinute;

    return DragTarget<Map<String, dynamic>>(
      onWillAcceptWithDetails: (_) {
        if (!_dropActive) setState(() => _dropActive = true);
        return true;
      },
      onLeave: (_) {
        if (_dropActive) setState(() => _dropActive = false);
      },
      onAcceptWithDetails: (details) async {
        setState(() => _dropActive = false);
        await _handleDrop(details.data, details.offset);
      },
      builder: (ctx, candidate, rejected) => SizedBox(
        key: _gridKey,
        height: widget.totalHeight,
        child: Stack(
          children: [
            // Drop-target highlight while a session is dragged over.
            if (_dropActive)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: KsColors.primary.withValues(alpha: 0.05),
                    border: Border.all(
                        color: KsColors.primary.withValues(alpha: 0.5)),
                  ),
                ),
              ),
            // Tap layer: tapping an empty slot on the column drops the new
            // session sheet in pre-anchored to that day + nearest half-hour.
            // Sits behind the session blocks so blocks absorb taps that
            // land on them.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) {
                  final minutesFromStart =
                      (details.localPosition.dy / pxPerMinute).round();
                  // Snap to the nearest 30 minutes so the start time is a
                  // sensible round figure rather than something like 09:17.
                  final snapped = (minutesFromStart / 30).round() * 30;
                  final clamped = snapped.clamp(
                      0, (_calendarEndHour - _calendarStartHour) * 60 - 30);
                  final totalMins = _calendarStartHour * 60 + clamped;
                  final hour = totalMins ~/ 60;
                  final minute = totalMins % 60;
                  _showAddSessionSheet(
                    context,
                    ref,
                    widget.date,
                    initialStartTime: TimeOfDay(hour: hour, minute: minute),
                  );
                },
              ),
            ),
            // Hour gridlines.
            ...List.generate(_calendarEndHour - _calendarStartHour, (i) {
              final y = i * 60 * pxPerMinute;
              return Positioned(
                left: 0,
                right: 0,
                top: y,
                child: Container(
                  height: 1,
                  decoration: const BoxDecoration(
                    border: Border(
                        top: BorderSide(color: KsColors.border, width: 1)),
                  ),
                ),
              );
            }),

            // Session blocks.
            ...positioned.map((ps) {
              final s = ps.session;
              final startMins =
                  ps.start.hour * 60 + ps.start.minute - startMinutes;
              final durMins = ps.end.difference(ps.start).inMinutes;
              final top = (startMins.clamp(
                          0, (_calendarEndHour - _calendarStartHour) * 60)) *
                      pxPerMinute;
              final bottomCap = (_calendarEndHour - _calendarStartHour) * 60;
              final endCapped =
                  (startMins + durMins).clamp(startMins, bottomCap);
              final height =
                  ((endCapped - startMins).clamp(20, bottomCap)) * pxPerMinute;

              final alignX = ps.lanesInCluster <= 1
                  ? 0.0
                  : -1 + (2.0 * ps.lane / (ps.lanesInCluster - 1));
              return Positioned(
                top: top.toDouble(),
                left: 0,
                right: 0,
                height: height.toDouble(),
                child: FractionallySizedBox(
                  widthFactor: 1.0 / ps.lanesInCluster,
                  alignment: Alignment(alignX, 0),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                    child: _SessionBlock(session: s, pxPerMinute: pxPerMinute),
                  ),
                ),
              );
            }),
          ],
        ),
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

/// Fixed bar shown when bulk-select has at least one session. Reads
/// the selection count, offers Cancel/Clear actions, runs the batch
/// call after a reason prompt.
class _BulkActionBar extends ConsumerWidget {
  const _BulkActionBar();

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final ids = ref.read(_bulkSelectionProvider).toList();
    if (ids.isEmpty) return;
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancel ${ids.length} session${ids.length == 1 ? '' : 's'}?'),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Every active booking on these sessions will be cancelled and any waitlist dropped. Students get a notification.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: reasonCtrl,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional, shown to students)',
                  hintText: 'e.g. Snow warning — sessions rescheduled',
                ),
              ),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep them')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel sessions',
                style: TextStyle(color: KsColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final res = await ref.read(apiClientProvider).cancelSessionsBatch(
            sessionIds: ids,
            reason: reasonCtrl.text.trim(),
          );
      ref.invalidate(masterCalendarProvider);
      ref.read(_bulkSelectionProvider.notifier).state = const {};
      ref.read(_bulkSelectModeProvider.notifier).state = false;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Cancelled ${res.sessionsCancelled} session${res.sessionsCancelled == 1 ? '' : 's'} · ${res.bookingsCancelled} booking${res.bookingsCancelled == 1 ? '' : 's'} affected'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not cancel: $e'),
          backgroundColor: KsColors.danger,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(_bulkSelectionProvider);
    final n = selection.length;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(
          color: KsColors.ink,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          boxShadow: KsShadows.sh1,
        ),
        child: Row(children: [
          Icon(Icons.event_busy_outlined, color: KsColors.surface, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$n session${n == 1 ? '' : 's'} selected',
              style: GoogleFonts.plusJakartaSans(
                  color: KsColors.surface,
                  fontWeight: FontWeight.w700,
                  fontSize: 14),
            ),
          ),
          TextButton(
            onPressed: () => ref.read(_bulkSelectionProvider.notifier).state = const {},
            child: const Text('Clear',
                style: TextStyle(color: KsColors.ink3)),
          ),
          const SizedBox(width: 4),
          ElevatedButton.icon(
            onPressed: () => _confirm(context, ref),
            icon: const Icon(Icons.event_busy_outlined, size: 16),
            label: const Text('Cancel sessions'),
            style: ElevatedButton.styleFrom(
              backgroundColor: KsColors.danger,
              foregroundColor: Colors.white,
            ),
          ),
        ]),
      ),
    );
  }
}

class _SessionBlock extends ConsumerWidget {
  final Map<String, dynamic> session;
  // pxPerMinute lets the drag feedback ghost match the block's rendered
  // height so the cursor sits in the same spot when the user picks it
  // up. Defaults to a sensible mid-density value for callers that don't
  // know (e.g. legacy uses outside the grid).
  final double pxPerMinute;
  const _SessionBlock({required this.session, this.pxPerMinute = 1.5});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final code = (session['courseCode'] ?? '').toString();
    final hex = (session['courseAccentColour'] ?? '').toString();
    final colour = _colourForCode(code, hex);
    final id = (session['sessionId'] ?? session['id'] ?? '').toString();
    final selectMode = ref.watch(_bulkSelectModeProvider);
    final selection = ref.watch(_bulkSelectionProvider);
    final selected = selection.contains(id);

    // Cancelled sessions stay visible (so the manager remembers "we
    // had this booked here") but go to ~40% opacity with a diagonal
    // strikethrough overlay, so you can never confuse one with a live
    // slot.
    final isCancelled = (session['status'] ?? '').toString() == 'cancelled';
    final block = InkWell(
      onTap: () {
        if (selectMode) {
          if (id.isEmpty) return;
          final next = {...selection};
          selected ? next.remove(id) : next.add(id);
          ref.read(_bulkSelectionProvider.notifier).state = next;
          return;
        }
        showDialog(
          context: context,
          builder: (_) => _SessionDetailDialog(session: session),
        );
      },
      borderRadius: BorderRadius.circular(KsRadius.sm),
      // Clip the block: short-duration sessions don't have room for
      // every detail line (course/time/location/instructor/students),
      // and without clipping Flutter raises overflow warnings + the
      // text bleeds into neighbouring blocks. Clipping keeps the look
      // tidy at any density.
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? colour.withValues(alpha: 0.32)
              : colour.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(KsRadius.sm),
          border: Border(
            left: BorderSide(color: colour, width: 3),
            top: selected ? BorderSide(color: colour, width: 1.5) : BorderSide.none,
            right: selected ? BorderSide(color: colour, width: 1.5) : BorderSide.none,
            bottom: selected ? BorderSide(color: colour, width: 1.5) : BorderSide.none,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          Opacity(
            opacity: isCancelled ? 0.4 : 1.0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: _BlockBody(session: session, accent: colour),
            ),
          ),
          if (isCancelled)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _StrikethroughPainter(colour: KsColors.danger),
                ),
              ),
            ),
          if (isCancelled)
            Positioned(
              top: 2,
              right: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: KsColors.danger,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                ),
                child: const Text('Cancelled',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3)),
              ),
            ),
        ]),
      ),
    );

    // In bulk-select mode, drag would conflict with selection — disable.
    if (selectMode) return block;

    final startsAt = DateTime.tryParse(session['startsAt'] ?? '')?.toLocal();
    final endsAt = DateTime.tryParse(session['endsAt'] ?? '')?.toLocal();
    final durationMins = (startsAt != null && endsAt != null)
        ? endsAt.difference(startsAt).inMinutes
        : 60;
    final ghostHeight = (durationMins * pxPerMinute).clamp(28.0, 240.0);
    return LongPressDraggable<Map<String, dynamic>>(
      data: session,
      // delay a touch so long-press doesn't trigger on accidental holds.
      delay: const Duration(milliseconds: 220),
      // Decorative drag feedback — looks like the block, slightly lifted.
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 140,
          height: ghostHeight.toDouble(),
          child: Opacity(
            opacity: 0.85,
            child: Container(
              decoration: BoxDecoration(
                color: colour.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(KsRadius.sm),
                border: Border(left: BorderSide(color: colour, width: 3)),
                boxShadow: KsShadows.sh2,
              ),
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: _BlockBody(session: session, accent: colour),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: block),
      child: block,
    );
  }
}

/// Diagonal strikethrough overlay for cancelled session blocks. A
/// translucent line corner-to-corner — readable at any block size, no
/// per-text strikethrough fiddling required.
class _StrikethroughPainter extends CustomPainter {
  final Color colour;
  const _StrikethroughPainter({required this.colour});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour.withValues(alpha: 0.45)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(2, size.height - 2),
      Offset(size.width - 2, 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(_StrikethroughPainter old) => old.colour != colour;
}

class _BlockBody extends StatelessWidget {
  final Map<String, dynamic> session;
  final Color accent;
  const _BlockBody({required this.session, required this.accent});

  @override
  Widget build(BuildContext context) {
    final tf = DateFormat('HH:mm');
    final startsAt = DateTime.tryParse(session['startsAt'] ?? '')?.toLocal();
    final endsAt = DateTime.tryParse(session['endsAt'] ?? '')?.toLocal();
    final timeStr = (startsAt == null || endsAt == null)
        ? ''
        : '${tf.format(startsAt)}–${tf.format(endsAt)}';
    final nonTeaching = session['nonTeaching'] ?? false;
    final locationName = (session['locationName'] ?? '').toString();
    final instructors =
        ((session['instructors'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final instructorLabel = instructors.isEmpty
        ? (session['instructorName']?.toString() ?? '')
        : instructors.map((i) => (i['name'] ?? '').toString().split(' ').first).join(', ');
    final hasInstructor = instructorLabel.isNotEmpty;
    final students =
        ((session['students'] as List?) ?? const []).cast<Map<String, dynamic>>();
    // Short sessions at moderate zoom can push the content past the
    // block's clipped height. The outer ClipPath already hides the
    // visual overflow; this LayoutBuilder + OverflowBox stops Flutter
    // logging a RenderFlex overflow on the way through. Anything that
    // doesn't fit is silently trimmed at the bottom — the block is a
    // glanceable summary, not the source of truth.
    return LayoutBuilder(builder: (ctx, c) => ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: c.maxWidth,
        maxWidth: c.maxWidth,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          session['courseName']?.toString() ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.plusJakartaSans(
            color: accent.computeLuminance() > 0.5 ? KsColors.ink : KsColors.ink,
            fontWeight: FontWeight.w800,
            fontSize: 11,
            height: 1.2,
          ),
        ),
        if (timeStr.isNotEmpty)
          Text(timeStr,
              style: const TextStyle(
                  color: KsColors.ink2, fontSize: 10, fontWeight: FontWeight.w600)),
        if (locationName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Row(children: [
              const Icon(Icons.place_outlined, size: 10, color: KsColors.ink3),
              const SizedBox(width: 2),
              Flexible(
                child: Text(locationName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: KsColors.ink3,
                        fontSize: 10,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        // Instructors — when there's no one yet, surface as a red
        // chip so the manager spots scaffolded shells quickly.
        if (hasInstructor)
          Text(instructorLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: KsColors.ink3, fontSize: 10))
        else
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('Needs instructor',
                style: TextStyle(
                    color: KsColors.danger,
                    fontSize: 9,
                    fontWeight: FontWeight.w800)),
          ),
        if (students.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: RichText(
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: const TextStyle(
                    color: KsColors.ink2,
                    fontSize: 9,
                    fontWeight: FontWeight.w700),
                children: [
                  for (var i = 0; i < students.length; i++) ...[
                    if (i > 0) const TextSpan(text: ', '),
                    ..._studentNameSpans(students[i]),
                  ],
                ],
              ),
            ),
          ),
          if (students.any((s) => (s['status'] ?? '') == 'cancelled')) ...[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                '${students.where((s) => (s['status'] ?? '') == 'cancelled').length} cancelled',
                style: const TextStyle(
                    color: KsColors.danger,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3),
              ),
            ),
          ],
        ],
        if (nonTeaching)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('Test day',
                style: TextStyle(
                    color: KsColors.warning,
                    fontSize: 9,
                    fontWeight: FontWeight.w800)),
          ),
      ],
        ),
      ),
    ));
  }

  /// Render one student name with a leading status glyph: ⚠ in
  /// warning-tone for `needs_reassignment`, ⊘ in grey for `no_show`,
  /// red strikethrough for `cancelled`. Default `booked` / `completed`
  /// → no glyph, just the name. Glyphs are tiny (font-size 9) so
  /// they don't crowd the block at any density.
  Iterable<InlineSpan> _studentNameSpans(Map<String, dynamic> s) {
    final status = (s['status'] ?? '').toString();
    final first =
        (s['name'] ?? '').toString().split(' ').first;
    InlineSpan? glyph;
    TextStyle? nameStyle;
    switch (status) {
      case 'needs_reassignment':
        glyph = const WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: EdgeInsets.only(right: 2),
            child: Icon(Icons.warning_amber_rounded,
                size: 10, color: KsColors.warning),
          ),
        );
        nameStyle = const TextStyle(color: KsColors.warning);
      case 'no_show':
        // No-show is per-student and the person actively failed to
        // turn up — the manager wants to see it clearly, not buried in
        // grey. Red X + red strikethrough on the name.
        glyph = const WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: EdgeInsets.only(right: 2),
            child: Icon(Icons.close,
                size: 10, color: KsColors.danger),
          ),
        );
        nameStyle = const TextStyle(
            color: KsColors.danger,
            decoration: TextDecoration.lineThrough,
            decorationColor: KsColors.danger);
      case 'cancelled':
        nameStyle = const TextStyle(
            color: KsColors.ink4,
            decoration: TextDecoration.lineThrough,
            decorationColor: KsColors.danger);
      case 'completed':
        nameStyle = const TextStyle(color: KsColors.success);
    }
    return [
      if (glyph != null) glyph,
      TextSpan(text: first, style: nameStyle),
    ];
  }
}

// ----- Session detail dialog -----

/// Family-keyed by session id so two open dialogs don't fight over
/// the same future. autoDispose keeps the surface clean once the
/// dialog closes.
final sessionWaitlistProvider = FutureProvider.autoDispose
    .family<({List<Map<String, dynamic>> entries, int count}), String>(
        (ref, sessionId) async {
  return ref.read(apiClientProvider).listSessionWaitlist(sessionId);
});

class _SessionDetailDialog extends ConsumerWidget {
  final Map<String, dynamic> session;
  const _SessionDetailDialog({required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final startsAt = DateTime.tryParse(session['startsAt'] ?? '')?.toLocal();
    final endsAt = DateTime.tryParse(session['endsAt'] ?? '')?.toLocal();
    final df = DateFormat('EEE d MMM yyyy');
    final tf = DateFormat('HH:mm');
    final active = (session['activeBookings'] as num?)?.toInt() ?? 0;
    final capacity = (session['capacity'] as num?)?.toInt() ?? 0;
    final sessionId = (session['sessionId'] ?? session['id'] ?? '').toString();
    // Only spend the call when the seat is actually contested — a
    // half-empty session doesn't need a waitlist row.
    final waitlistAsync = (sessionId.isNotEmpty && active >= capacity)
        ? ref.watch(sessionWaitlistProvider(sessionId))
        : null;
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
              if (waitlistAsync != null)
                waitlistAsync.when(
                  loading: () => _row(Icons.hourglass_top_outlined, 'Loading waitlist…'),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (data) => data.count == 0
                      ? const SizedBox.shrink()
                      : _WaitlistList(sessionId: sessionId, entries: data.entries),
                ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: sessionId.isEmpty
                        ? null
                        : () {
                            Navigator.pop(context);
                            _showEditSessionSheet(context, ref, session);
                          },
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: sessionId.isEmpty
                        ? null
                        : () async {
                            final ok = await _confirmCancel(context);
                            if (!ok) return;
                            try {
                              await ref
                                  .read(apiClientProvider)
                                  .cancelSessionsBatch(
                                      sessionIds: [sessionId],
                                      reason: 'Cancelled from calendar');
                              ref.invalidate(masterCalendarProvider);
                              if (context.mounted) Navigator.pop(context);
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content:
                                            Text('Could not cancel: $e'),
                                        backgroundColor: KsColors.danger,
                                        behavior:
                                            SnackBarBehavior.floating));
                              }
                            }
                          },
                    icon: const Icon(Icons.cancel_outlined, size: 16),
                    label: const Text('Cancel session'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KsColors.danger,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmCancel(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this session?'),
        content: const Text(
            'Active bookings will be cancelled and the slot will disappear from the calendar. Students will be notified.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: KsColors.danger,
                foregroundColor: Colors.white),
            child: const Text('Cancel session'),
          ),
        ],
      ),
    );
    return ok == true;
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

class _WaitlistList extends ConsumerWidget {
  final String sessionId;
  final List<Map<String, dynamic>> entries;
  const _WaitlistList({required this.sessionId, required this.entries});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.hourglass_top_outlined,
                color: KsColors.ink3, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${entries.length} on the waitlist — first will be booked when a seat opens.',
                style: const TextStyle(color: KsColors.ink2, fontSize: 13),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: KsColors.primaryTint,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('#${e['position'] ?? '?'}',
                      style: const TextStyle(
                          color: KsColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 11)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    (e['studentName'] ?? e['studentId'] ?? '').toString(),
                    style:
                        const TextStyle(color: KsColors.ink, fontSize: 13),
                  ),
                ),
                _WaitlistRemoveButton(
                  sessionId: sessionId,
                  entryId: (e['id'] ?? '').toString(),
                  studentName: (e['studentName'] ?? '').toString(),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}

class _WaitlistRemoveButton extends ConsumerStatefulWidget {
  final String sessionId;
  final String entryId;
  final String studentName;
  const _WaitlistRemoveButton({
    required this.sessionId,
    required this.entryId,
    required this.studentName,
  });

  @override
  ConsumerState<_WaitlistRemoveButton> createState() =>
      _WaitlistRemoveButtonState();
}

class _WaitlistRemoveButtonState
    extends ConsumerState<_WaitlistRemoveButton> {
  bool _removing = false;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Remove ${widget.studentName}',
      icon: _removing
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.close, size: 16, color: KsColors.ink3),
      onPressed: _removing ? null : _remove,
      visualDensity: VisualDensity.compact,
    );
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from waitlist?'),
        content: Text('Remove ${widget.studentName} from this session\'s waitlist? They won\'t be auto-booked when a seat opens.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _removing = true);
    try {
      await ref
          .read(apiClientProvider)
          .removeWaitlistEntry(widget.sessionId, widget.entryId);
      ref.invalidate(sessionWaitlistProvider(widget.sessionId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't remove: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }
}

// ---------- Edit session sheet ----------

Future<void> _showEditSessionSheet(
    BuildContext context, WidgetRef ref, Map<String, dynamic> session) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _EditSessionSheet(session: session),
  );
}

class _EditSessionSheet extends ConsumerStatefulWidget {
  final Map<String, dynamic> session;
  const _EditSessionSheet({required this.session});

  @override
  ConsumerState<_EditSessionSheet> createState() => _EditSessionSheetState();
}

class _EditSessionSheetState extends ConsumerState<_EditSessionSheet> {
  late DateTime _date;
  late TimeOfDay _startTime;
  late final TextEditingController _duration;
  late final TextEditingController _capacity;
  late Set<String> _instructorIds;
  late List<Map<String, dynamic>> _students; // mutated on add/remove
  late final DateTime _initialStart;
  late final int _initialDurationMins;
  late final int _initialCapacity;
  late final Set<String> _initialInstructors;
  bool _saving = false;
  bool _rosterBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final start = DateTime.tryParse(widget.session['startsAt'] ?? '')?.toLocal() ??
        DateTime.now();
    final end = DateTime.tryParse(widget.session['endsAt'] ?? '')?.toLocal() ??
        start.add(const Duration(hours: 1));
    final dur = end.difference(start).inMinutes;
    final cap = (widget.session['capacity'] as num?)?.toInt() ?? 1;
    final instructorList =
        ((widget.session['instructors'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
    _date = DateTime(start.year, start.month, start.day);
    _startTime = TimeOfDay(hour: start.hour, minute: start.minute);
    _duration = TextEditingController(text: dur.toString());
    _capacity = TextEditingController(text: cap.toString());
    _instructorIds = {
      for (final i in instructorList) (i['id'] ?? '').toString()
    }..removeWhere((s) => s.isEmpty);
    if (_instructorIds.isEmpty) {
      // Fall back to the legacy single-instructor field if the join
      // payload wasn't populated (older calendar payloads).
      final legacy = (widget.session['instructorId'] ?? '').toString();
      if (legacy.isNotEmpty) _instructorIds.add(legacy);
    }
    _initialStart = start;
    _initialDurationMins = dur;
    _initialCapacity = cap;
    _initialInstructors = {..._instructorIds};
    _students = [
      ...((widget.session['students'] as List?) ?? const [])
          .cast<Map<String, dynamic>>(),
    ];
  }

  /// Remove a booking from this session. Just calls `cancelBooking` —
  /// the engine handles waitlist promotion, notifications, etc.
  Future<void> _removeStudent(Map<String, dynamic> student) async {
    final bookingId = (student['bookingId'] ?? '').toString();
    if (bookingId.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('Missing booking id — try refreshing the calendar.'),
        backgroundColor: KsColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    setState(() => _rosterBusy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(apiClientProvider)
          .cancelBooking(bookingId, reason: 'Removed by manager');
      setState(() {
        _students.removeWhere(
            (s) => (s['bookingId'] ?? '').toString() == bookingId);
      });
      ref.invalidate(masterCalendarProvider);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(
        content: Text('Could not remove: $e'),
        backgroundColor: KsColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _rosterBusy = false);
    }
  }

  /// Book another student onto this session. The engine auto-assigns a
  /// suitable bike, mirroring the student-self-serve flow.
  Future<void> _addStudent() async {
    final picked = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KsColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
      ),
      builder: (_) => _AddStudentSheet(
          excludeIds: _students
              .map((s) => (s['id'] ?? '').toString())
              .where((s) => s.isNotEmpty)
              .toSet()),
    );
    if (picked == null || !mounted) return;
    final sessionId =
        (widget.session['sessionId'] ?? widget.session['id'] ?? '')
            .toString();
    if (sessionId.isEmpty) return;
    setState(() => _rosterBusy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final res = await ref.read(apiClientProvider).book(
            sessionId: sessionId,
            studentId: picked['id'],
          );
      // Best-effort: insert into local list so the UI updates without
      // a calendar round-trip. BookingResult doesn't carry the bike
      // nickname (the engine looks it up later), so we just label it
      // "Bike assigned" until the next calendar refresh fills it in.
      setState(() {
        _students.add({
          'id': picked['id'],
          'name': picked['name'],
          'status': 'booked',
          'bookingId': res.booking.id,
          'bikeId': res.booking.bikeId,
          'bikeNickname': 'Bike assigned',
        });
      });
      ref.invalidate(masterCalendarProvider);
    } on ApiException catch (e) {
      messenger?.showSnackBar(SnackBar(
        content: Text('Could not add: ${e.message}'),
        backgroundColor: KsColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(
        content: Text('Could not add: $e'),
        backgroundColor: KsColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _rosterBusy = false);
    }
  }

  @override
  void dispose() {
    _duration.dispose();
    _capacity.dispose();
    super.dispose();
  }

  DateTime get _newStart => DateTime(_date.year, _date.month, _date.day,
      _startTime.hour, _startTime.minute);

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 1),
      lastDate: DateTime(_date.year + 2),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );
    if (picked != null) setState(() => _startTime = picked);
  }

  Future<void> _submit() async {
    final dur = int.tryParse(_duration.text);
    final cap = int.tryParse(_capacity.text);
    if (dur == null || dur <= 0) {
      setState(() => _error = 'Duration must be a positive number of minutes.');
      return;
    }
    if (cap == null || cap <= 0) {
      setState(() => _error = 'Capacity must be a positive number.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final id = (widget.session['sessionId'] ?? widget.session['id'] ?? '')
        .toString();
    final api = ref.read(apiClientProvider);
    final newStart = _newStart;
    final newEnd = newStart.add(Duration(minutes: dur));
    try {
      // Only send the fields that actually moved so the audit row
      // describes what really changed.
      final timeChanged =
          newStart != _initialStart || dur != _initialDurationMins;
      final capChanged = cap != _initialCapacity;
      if (timeChanged || capChanged) {
        await api.updateSession(
          sessionId: id,
          startsAt: timeChanged ? newStart : null,
          endsAt: timeChanged ? newEnd : null,
          capacity: capChanged ? cap : null,
        );
      }
      final instrChanged = !_setsEqual(_instructorIds, _initialInstructors);
      if (instrChanged) {
        await api.setSessionInstructors(
          sessionId: id,
          instructorIds: _instructorIds.toList(),
        );
      }
      ref.invalidate(masterCalendarProvider);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not save: $e';
        _saving = false;
      });
    }
  }

  bool _setsEqual(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final x in a) {
      if (!b.contains(x)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final instructors = ref.watch(instructorsProvider).valueOrNull ?? const [];
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4,
                    width: 36,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: KsColors.border2,
                      borderRadius: BorderRadius.circular(KsRadius.pill),
                    ),
                  ),
                ),
                Text('Edit session',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink)),
                const SizedBox(height: 4),
                Text(
                  '${widget.session['courseCode'] ?? ''} · ${widget.session['locationName'] ?? ''}',
                  style: const TextStyle(color: KsColors.ink3, fontSize: 13),
                ),
                const SizedBox(height: 16),

                Row(children: [
                  Expanded(child: _editLabel('Date')),
                  Expanded(child: _editLabel('Start time')),
                ]),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.event, size: 16),
                      label: Text(DateFormat('EEE d MMM').format(_date)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule, size: 16),
                      label: Text(_startTime.format(context)),
                    ),
                  ),
                ]),
                const SizedBox(height: 14),

                Row(children: [
                  Expanded(child: _editLabel('Duration (min)')),
                  Expanded(child: _editLabel('Capacity')),
                ]),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _duration,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _capacity,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(border: OutlineInputBorder()),
                    ),
                  ),
                ]),
                const SizedBox(height: 14),

                _editLabel('Instructors'),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  _editChip('Unassigned',
                      selected: _instructorIds.isEmpty,
                      onTap: () => setState(() => _instructorIds.clear())),
                  for (final i in instructors)
                    _editChip(i.name,
                        selected: _instructorIds.contains(i.userId),
                        onTap: () => setState(() {
                              if (_instructorIds.contains(i.userId)) {
                                _instructorIds.remove(i.userId);
                              } else {
                                _instructorIds.add(i.userId);
                              }
                            })),
                ]),

                ..._bikesSection(),

                const SizedBox(height: 18),
                Row(children: [
                  Expanded(child: _editLabel('Roster · ${_students.length}')),
                  if (_rosterBusy)
                    const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    TextButton.icon(
                      onPressed: _addStudent,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add student'),
                      style: TextButton.styleFrom(
                          foregroundColor: KsColors.primaryDeep),
                    ),
                ]),
                if (_students.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: KsColors.surface2,
                      borderRadius: BorderRadius.circular(KsRadius.md),
                      border: Border.all(color: KsColors.border),
                    ),
                    child: const Text(
                        'No students booked. Tap "Add student" to book someone in.',
                        style: TextStyle(color: KsColors.ink3, fontSize: 13)),
                  )
                else
                  Container(
                    decoration: BoxDecoration(
                      color: KsColors.surface,
                      borderRadius: BorderRadius.circular(KsRadius.md),
                      border: Border.all(color: KsColors.border),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < _students.length; i++)
                          _rosterRow(_students[i], i == _students.length - 1),
                      ],
                    ),
                  ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: KsColors.dangerTint,
                      borderRadius: BorderRadius.circular(KsRadius.md),
                    ),
                    child: Text(_error!,
                        style: const TextStyle(color: KsColors.danger)),
                  ),
                ],

                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _saving ? null : _submit,
                  icon: _saving
                      ? const SizedBox.shrink()
                      : const Icon(Icons.check, size: 18),
                  label: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5))
                      : const Text('Save changes'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _editLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(text.toUpperCase(),
            style: GoogleFonts.plusJakartaSans(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: KsColors.ink3,
                letterSpacing: 0.6)),
      );

  Widget _editChip(String label,
      {required bool selected, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? KsColors.primaryTint : KsColors.surface2,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(
              color: selected
                  ? KsColors.primary.withValues(alpha: 0.5)
                  : KsColors.border,
              width: selected ? 1.5 : 1),
        ),
        child: Text(label,
            style: GoogleFonts.plusJakartaSans(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: selected ? KsColors.primaryDeep : KsColors.ink2)),
      ),
    );
  }

  /// Bikes attached to the session — grouped by bikeId, with all riders
  /// of each bike listed in the "With …" caption. The engine guards
  /// against two active bookings sharing a bike (findSuitableFreeBikes
  /// excludes any bike with an overlapping booked/needs_reassignment
  /// row), so multi-rider rows in practice only happen when one or
  /// more bookings has wound down to no_show / cancelled / completed —
  /// but the row should still reflect the full picture instead of
  /// silently dropping anyone beyond the first. Each row offers Take
  /// offline (same flow as the instructor-side bikes section). Hidden
  /// when there are no bookings because there's nothing to attach a
  /// bike to yet.
  List<Widget> _bikesSection() {
    final bikeOrder = <String>[];
    final bikeNicknames = <String, String>{};
    final bikeRiders = <String, List<Map<String, String>>>{};
    for (final s in _students) {
      final id = (s['bikeId'] ?? '').toString();
      if (id.isEmpty) continue;
      if (!bikeRiders.containsKey(id)) {
        bikeOrder.add(id);
        bikeNicknames[id] = (s['bikeNickname'] ?? '').toString();
        bikeRiders[id] = [];
      }
      bikeRiders[id]!.add({
        'name': (s['name'] ?? '').toString(),
        'status': (s['status'] ?? '').toString(),
      });
    }
    final assignedIds = bikeRiders.keys.toSet();
    final sessionId =
        (widget.session['sessionId'] ?? widget.session['id'] ?? '').toString();
    final freeAsync = sessionId.isEmpty
        ? const AsyncValue<List<SuitableBike>>.data(<SuitableBike>[])
        : ref.watch(_suitableBikesForSessionProvider(sessionId));
    final free = (freeAsync.valueOrNull ?? const <SuitableBike>[])
        // Defence in depth: a free bike that's also somehow already
        // assigned on this session shouldn't double-list.
        .where((b) => !assignedIds.contains(b.bikeId))
        .toList();
    if (bikeOrder.isEmpty && free.isEmpty) return const [];
    return [
      const SizedBox(height: 18),
      _editLabel('Bikes'),
      const SizedBox(height: 6),
      Container(
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.md),
          border: Border.all(color: KsColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          if (bikeOrder.isNotEmpty) ...[
            _bikesSubheader('Assigned · ${bikeOrder.length}', isFirst: true),
            for (var i = 0; i < bikeOrder.length; i++)
              _bikeRow(
                id: bikeOrder[i],
                nickname: bikeNicknames[bikeOrder[i]] ?? '',
                riders: bikeRiders[bikeOrder[i]]!,
                last: i == bikeOrder.length - 1 && free.isEmpty,
              ),
          ],
          if (free.isNotEmpty) ...[
            _bikesSubheader('Free in this slot · ${free.length}',
                isFirst: bikeOrder.isEmpty),
            for (var i = 0; i < free.length; i++)
              _freeBikeRow(free[i], i == free.length - 1),
          ],
        ]),
      ),
    ];
  }

  /// Tiny inline subheader inside the Bikes container. Distinguishes
  /// "Assigned" rows from "Free in this slot" rows without adding the
  /// visual weight of a second card.
  Widget _bikesSubheader(String label, {required bool isFirst}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: KsColors.surface2,
        border: Border(
          top: isFirst
              ? BorderSide.none
              : const BorderSide(color: KsColors.border),
          bottom: const BorderSide(color: KsColors.border),
        ),
      ),
      child: Text(label.toUpperCase(),
          style: GoogleFonts.plusJakartaSans(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: KsColors.ink3,
              letterSpacing: 0.5)),
    );
  }

  /// One row for a bike that's free + suitable for this session — the
  /// engine would auto-assign it if a new student booked in. Read-only
  /// for now: the user has explicit add-student / swap-bike flows
  /// already; this row is just situational awareness ("how much
  /// headroom do I have?").
  Widget _freeBikeRow(SuitableBike b, bool last) {
    final label =
        b.nickname.isEmpty ? b.registration : b.nickname;
    final meta = [
      if (b.registration.isNotEmpty && b.nickname.isNotEmpty) b.registration,
      if (b.category.isNotEmpty) b.category,
      if (b.transmission.isNotEmpty) b.transmission,
      if (b.isCrossSite && b.currentLocationName.isNotEmpty)
        'at ${b.currentLocationName}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: last
              ? BorderSide.none
              : const BorderSide(color: KsColors.border),
        ),
      ),
      child: Row(children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: KsColors.successTint,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.two_wheeler,
              color: KsColors.success, size: 14),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: KsColors.ink)),
              if (meta.isNotEmpty)
                Text(meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: KsColors.ink3, fontSize: 11.5)),
            ],
          ),
        ),
        if (b.isCrossSite)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: KsColors.warningTint,
              borderRadius: BorderRadius.circular(KsRadius.pill),
            ),
            child: Text('Cross-site',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: KsColors.warning)),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: KsColors.successTint,
              borderRadius: BorderRadius.circular(KsRadius.pill),
            ),
            child: Text('Free',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: KsColors.success)),
          ),
        // Take offline also lives on free bikes — start-of-day check
        // case, manager spots a fault before anyone gets on. Same
        // sheet + same backend path as the assigned-bike row.
        TextButton.icon(
          onPressed: () => TakeBikeOfflineSheet.show(
            context,
            bikeId: b.bikeId,
            bikeLabel: label,
            onDone: () {
              ref.invalidate(masterCalendarProvider);
              ref.invalidate(_suitableBikesForSessionProvider(
                  (widget.session['sessionId'] ?? widget.session['id'] ?? '')
                      .toString()));
            },
          ),
          icon: const Icon(Icons.do_not_disturb_on_outlined, size: 14),
          label: const Text('Take offline'),
          style: TextButton.styleFrom(
            foregroundColor: KsColors.warning,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 28),
            visualDensity: VisualDensity.compact,
          ),
        ),
      ]),
    );
  }

  Widget _bikeRow({
    required String id,
    required String nickname,
    required List<Map<String, String>> riders,
    required bool last,
  }) {
    final label = nickname.isEmpty ? id : nickname;
    final caption = _ridersCaption(riders);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: last
              ? BorderSide.none
              : const BorderSide(color: KsColors.border),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: KsColors.primaryTint,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.two_wheeler,
                color: KsColors.primaryDeep, size: 15),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink)),
                if (caption.isNotEmpty)
                  Text(caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: KsColors.ink3, fontSize: 11.5)),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => TakeBikeOfflineSheet.show(
              context,
              bikeId: id,
              bikeLabel: label,
              onDone: () => ref.invalidate(masterCalendarProvider),
            ),
            icon: const Icon(Icons.do_not_disturb_on_outlined, size: 15),
            label: const Text('Take offline'),
            style: TextButton.styleFrom(foregroundColor: KsColors.warning),
          ),
        ],
      ),
    );
  }

  /// "With Alex Hughes, Mark Doherty (no-show)" — joins every rider on
  /// a bike with a status suffix on anyone who isn't actively booked
  /// any more, so the manager can tell at a glance whether the bike's
  /// really being used or just historically attached.
  String _ridersCaption(List<Map<String, String>> riders) {
    if (riders.isEmpty) return '';
    final parts = riders.map((r) {
      final name = (r['name'] ?? '').trim();
      final suffix = switch (r['status'] ?? '') {
        'no_show' => ' (no-show)',
        'cancelled' => ' (cancelled)',
        'completed' => ' (done)',
        'needs_reassignment' => ' (needs reassign)',
        _ => '',
      };
      return '$name$suffix';
    }).where((s) => s.trim().isNotEmpty).toList();
    if (parts.isEmpty) return '';
    return 'With ${parts.join(', ')}';
  }

  Widget _rosterRow(Map<String, dynamic> student, bool last) {
    final name = (student['name'] ?? '').toString();
    final bike = (student['bikeNickname'] ?? '').toString();
    final bikeId = (student['bikeId'] ?? '').toString();
    final status = (student['status'] ?? '').toString();
    final canRemove =
        status == 'booked' || status == 'needs_reassignment';
    final canSwap = canRemove; // same gate; cancelled/completed are read-only
    // Visual signal that the row is "done" — completed, no-show or
    // cancelled all read as immutable history. Strikes through name +
    // dims the avatar so the active rows stand out.
    final isFinal =
        status == 'completed' || status == 'no_show' || status == 'cancelled';
    final visuals = _rosterStatusVisuals(status, bikeId.isEmpty);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: last
              ? BorderSide.none
              : const BorderSide(color: KsColors.border),
        ),
      ),
      child: Row(children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: visuals.avatarBg,
            borderRadius: BorderRadius.circular(KsRadius.pill),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.person, color: visuals.avatarFg, size: 16),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: isFinal ? KsColors.ink3 : KsColors.ink,
                      decoration: (status == 'no_show' || status == 'cancelled')
                          ? TextDecoration.lineThrough
                          : null,
                      decorationColor: status == 'no_show'
                          ? KsColors.danger
                          : (status == 'cancelled'
                              ? KsColors.danger
                              : null))),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: InkWell(
                  onTap: canSwap ? () => _swapBike(student) : null,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: KsColors.surface2,
                      borderRadius: BorderRadius.circular(KsRadius.pill),
                      border: Border.all(color: KsColors.border),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.two_wheeler,
                          size: 11, color: KsColors.ink3),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          bike.isEmpty ? 'No bike' : bike,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: bikeId.isEmpty
                                  ? KsColors.warning
                                  : KsColors.ink2,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (canSwap) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.swap_horiz,
                            size: 12, color: KsColors.ink4),
                      ],
                    ]),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (visuals.pillLabel != null)
          Tooltip(
            message: visuals.tooltip ?? '',
            waitDuration: const Duration(milliseconds: 300),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: visuals.pillBg,
                borderRadius: BorderRadius.circular(KsRadius.pill),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (visuals.pillIcon != null) ...[
                  Icon(visuals.pillIcon, size: 11, color: visuals.pillFg),
                  const SizedBox(width: 3),
                ],
                Text(visuals.pillLabel!,
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: visuals.pillFg)),
              ]),
            ),
          ),
        if (canRemove)
          IconButton(
            tooltip: 'Remove from session',
            onPressed: _rosterBusy ? null : () => _removeStudent(student),
            icon: const Icon(Icons.close, size: 18),
            color: KsColors.danger,
          ),
      ]),
    );
  }

  /// Per-status visuals for the roster row — avatar tones, the
  /// trailing pill (label + icon + colour) and a tooltip explaining
  /// what the status means in plain language. Kept here so each row's
  /// build stays readable.
  _RosterStatusVisuals _rosterStatusVisuals(String status, bool noBike) {
    switch (status) {
      case 'needs_reassignment':
        return _RosterStatusVisuals(
          avatarBg: KsColors.warningTint,
          avatarFg: KsColors.warning,
          pillBg: KsColors.warningTint,
          pillFg: KsColors.warning,
          pillIcon: Icons.warning_amber_rounded,
          pillLabel: 'Bike issue',
          tooltip:
              'Their bike was taken offline — needs swapping or cancelling. Tap the bike chip to swap.',
        );
      case 'no_show':
        return _RosterStatusVisuals(
          avatarBg: KsColors.dangerTint,
          avatarFg: KsColors.danger,
          pillBg: KsColors.dangerTint,
          pillFg: KsColors.danger,
          pillIcon: Icons.close,
          pillLabel: 'No-show',
          tooltip:
              'Student didn’t turn up. Charge stays on their account unless you void it manually.',
        );
      case 'cancelled':
        return _RosterStatusVisuals(
          avatarBg: KsColors.surface3,
          avatarFg: KsColors.ink4,
          pillBg: KsColors.surface3,
          pillFg: KsColors.ink3,
          pillIcon: Icons.event_busy_outlined,
          pillLabel: 'Cancelled',
          tooltip: 'Booking was cancelled. Seat is free.',
        );
      case 'completed':
        return _RosterStatusVisuals(
          avatarBg: KsColors.successTint,
          avatarFg: KsColors.success,
          pillBg: KsColors.successTint,
          pillFg: KsColors.success,
          pillIcon: Icons.check,
          pillLabel: 'Done',
          tooltip: 'Attended — competencies and notes captured in Assess.',
        );
    }
    // booked + anything else → default avatar, no pill.
    return _RosterStatusVisuals(
      avatarBg: noBike ? KsColors.warningTint : KsColors.primaryTint,
      avatarFg: noBike ? KsColors.warning : KsColors.primaryDeep,
    );
  }

  Future<void> _swapBike(Map<String, dynamic> student) async {
    final bookingId = (student['bookingId'] ?? '').toString();
    if (bookingId.isEmpty) return;
    final sessionId =
        (widget.session['sessionId'] ?? widget.session['id'] ?? '').toString();
    if (sessionId.isEmpty) return;
    final currentBikeId = (student['bikeId'] ?? '').toString();
    final picked = await showModalBottomSheet<({String id, String nickname})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KsColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
      ),
      builder: (_) => _BikePickerSheet(
        sessionId: sessionId,
        currentBikeId: currentBikeId,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _rosterBusy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(apiClientProvider).assignBookingBike(
            bookingId: bookingId,
            bikeId: picked.id,
          );
      setState(() {
        for (var i = 0; i < _students.length; i++) {
          if ((_students[i]['bookingId'] ?? '').toString() == bookingId) {
            _students[i] = {
              ..._students[i],
              'bikeId': picked.id,
              'bikeNickname': picked.nickname,
              // If it was needs_reassignment, the engine flips it back
              // to 'booked' on a successful swap — mirror locally.
              'status': (_students[i]['status'] == 'needs_reassignment')
                  ? 'booked'
                  : _students[i]['status'],
            };
          }
        }
      });
      ref.invalidate(masterCalendarProvider);
    } on ApiException catch (e) {
      messenger?.showSnackBar(SnackBar(
        content: Text('Couldn’t swap: ${e.message}'),
        backgroundColor: KsColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(
        content: Text('Couldn’t swap: $e'),
        backgroundColor: KsColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _rosterBusy = false);
    }
  }
}

/// Bundle of visual properties for a roster row, keyed off booking
/// status. Lives next to its consumer so the row's build method stays
/// close to the look it produces.
class _RosterStatusVisuals {
  final Color avatarBg;
  final Color avatarFg;
  final Color? pillBg;
  final Color? pillFg;
  final IconData? pillIcon;
  final String? pillLabel;
  final String? tooltip;
  const _RosterStatusVisuals({
    required this.avatarBg,
    required this.avatarFg,
    this.pillBg,
    this.pillFg,
    this.pillIcon,
    this.pillLabel,
    this.tooltip,
  });
}

/// Picker bottom-sheet for "Add student" from the edit session sheet.
/// Lists active students (alphabetical), with a tiny search box. Tap
/// returns `{id, name}` to the caller.
/// Picker bottom-sheet for swapping a booking's bike. Lists the
/// suitable-free bikes for the session (server already does the
/// category + transmission + double-booking filtering). The current
/// bike is shown selected so the manager can see what they're moving
/// away from; tapping returns `(id, nickname)` to the caller.
class _BikePickerSheet extends ConsumerWidget {
  final String sessionId;
  final String currentBikeId;
  const _BikePickerSheet({
    required this.sessionId,
    required this.currentBikeId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_suitableBikesForSessionProvider(sessionId));
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4,
                    width: 36,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: KsColors.border2,
                      borderRadius: BorderRadius.circular(KsRadius.pill),
                    ),
                  ),
                ),
                Text('Swap bike',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink)),
                const SizedBox(height: 4),
                const Text(
                    'Engine-filtered to bikes that fit this session and aren’t booked elsewhere.',
                    style: TextStyle(color: KsColors.ink3, fontSize: 12)),
                const SizedBox(height: 12),
                Expanded(
                  child: async.when(
                    loading: () => const Center(
                        child: CircularProgressIndicator(
                            color: KsColors.primary)),
                    error: (e, _) => Center(
                      child: Text('Couldn’t load bikes.\n$e',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: KsColors.danger)),
                    ),
                    data: (bikes) {
                      // The current bike is omitted from the suitable
                      // list (engine treats it as in-use by this very
                      // booking). Add it back as a disabled "Current"
                      // row so the manager can see what they're on.
                      if (bikes.isEmpty && currentBikeId.isEmpty) {
                        return const Center(
                          child: Text('No suitable bikes free for this slot.',
                              style: TextStyle(color: KsColors.ink3)),
                        );
                      }
                      return ListView.separated(
                        itemCount: bikes.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, color: KsColors.border),
                        itemBuilder: (ctx, i) {
                          final b = bikes[i];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: KsColors.primaryTint,
                                borderRadius:
                                    BorderRadius.circular(KsRadius.md),
                              ),
                              alignment: Alignment.center,
                              child: const Icon(Icons.two_wheeler,
                                  color: KsColors.primaryDeep, size: 18),
                            ),
                            title: Text(
                                b.nickname.isEmpty
                                    ? b.registration
                                    : b.nickname,
                                style: GoogleFonts.plusJakartaSans(
                                    fontWeight: FontWeight.w700,
                                    color: KsColors.ink)),
                            subtitle: Text(
                              [
                                b.registration,
                                b.category,
                                b.transmission,
                                if (b.isCrossSite) 'Cross-site',
                              ].where((s) => s.isNotEmpty).join(' · '),
                              style: const TextStyle(
                                  color: KsColors.ink3, fontSize: 12),
                            ),
                            onTap: () => Navigator.of(ctx).pop((
                              id: b.bikeId,
                              nickname: b.nickname.isEmpty
                                  ? b.registration
                                  : b.nickname,
                            )),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One-off provider so the picker sheet can fetch suitable bikes
/// without a screen-level provider getting in the way. Family-keyed
/// by session id; autoDispose so we don't keep stale lists around.
final _suitableBikesForSessionProvider =
    FutureProvider.autoDispose.family<List<SuitableBike>, String>((ref, sessionId) async {
  return ref.read(apiClientProvider).suitableBikesForSession(sessionId);
});

class _AddStudentSheet extends ConsumerStatefulWidget {
  final Set<String> excludeIds;
  const _AddStudentSheet({required this.excludeIds});

  @override
  ConsumerState<_AddStudentSheet> createState() => _AddStudentSheetState();
}

class _AddStudentSheetState extends ConsumerState<_AddStudentSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(studentsProvider(''));
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4,
                    width: 36,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: KsColors.border2,
                      borderRadius: BorderRadius.circular(KsRadius.pill),
                    ),
                  ),
                ),
                Text('Add student',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink)),
                const SizedBox(height: 10),
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Search by name…',
                  ),
                  onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: async.when(
                    loading: () => const Center(
                        child: CircularProgressIndicator(
                            color: KsColors.primary)),
                    error: (e, _) => Center(
                        child: Text('Couldn’t load students.\n$e',
                            style: const TextStyle(color: KsColors.danger))),
                    data: (students) {
                      final filtered = students.where((s) {
                        if (widget.excludeIds.contains(s.id)) return false;
                        if (_q.isEmpty) return true;
                        return s.name.toLowerCase().contains(_q);
                      }).toList();
                      if (filtered.isEmpty) {
                        return const Center(
                          child: Text('No matching students.',
                              style: TextStyle(color: KsColors.ink3)),
                        );
                      }
                      return ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, color: KsColors.border),
                        itemBuilder: (ctx, i) {
                          final s = filtered[i];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: KsColors.primaryTint,
                                borderRadius:
                                    BorderRadius.circular(KsRadius.pill),
                              ),
                              alignment: Alignment.center,
                              child: const Icon(Icons.person,
                                  color: KsColors.primaryDeep, size: 18),
                            ),
                            title: Text(s.name,
                                style: GoogleFonts.plusJakartaSans(
                                    fontWeight: FontWeight.w700,
                                    color: KsColors.ink)),
                            subtitle: Text(s.email,
                                style: const TextStyle(
                                    color: KsColors.ink3, fontSize: 12)),
                            onTap: () => Navigator.of(ctx).pop({
                              'id': s.id,
                              'name': s.name,
                            }),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Month view — 30 days of columns is unreadable, so we render each day
/// in the month as a section with its sessions listed below. Empty days
/// still show their date so the manager can scan for gaps.
class _MonthList extends ConsumerWidget {
  final DateTime anchor; // first day of the month
  final List<Map<String, dynamic>> sessions;
  const _MonthList({required this.anchor, required this.sessions});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                  // Date strip — tap to open the add-session sheet
                  // anchored to this day at the default start time.
                  InkWell(
                    onTap: () => _showAddSessionSheet(context, ref, date),
                    child: Container(
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
                          Row(children: [
                            Expanded(
                              child: Text(
                                  DateFormat('EEE').format(date).toUpperCase(),
                                  style: TextStyle(
                                      color: isToday
                                          ? KsColors.primaryDeep
                                          : KsColors.ink3,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 11,
                                      letterSpacing: 0.5)),
                            ),
                            const Icon(Icons.add_circle_outline,
                                size: 14, color: KsColors.ink4),
                          ]),
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
                  ),
                  // Sessions list / empty state
                  Expanded(
                    child: Padding(
                      padding:
                          const EdgeInsets.fromLTRB(14, 10, 14, 10),
                      child: sessionsForDay.isEmpty
                          ? InkWell(
                              onTap: () =>
                                  _showAddSessionSheet(context, ref, date),
                              child: Row(children: const [
                                Icon(Icons.add_circle_outline,
                                    color: KsColors.ink4, size: 14),
                                SizedBox(width: 6),
                                Text('Tap to add a session',
                                    style: TextStyle(
                                        color: KsColors.ink4, fontSize: 12.5)),
                              ]),
                            )
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
                                return InkWell(
                                  onTap: () => showDialog(
                                    context: context,
                                    builder: (_) =>
                                        _SessionDetailDialog(session: s),
                                  ),
                                  child: Padding(
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
                                      const Icon(Icons.chevron_right,
                                          color: KsColors.ink4, size: 16),
                                    ]),
                                  ),
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

// ---------- Add session sheet ----------

Future<void> _showAddSessionSheet(
  BuildContext context,
  WidgetRef ref,
  DateTime anchor, {
  TimeOfDay? initialStartTime,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _AddSessionSheet(
      initialDate: anchor,
      initialStartTime: initialStartTime,
    ),
  );
}

class _AddSessionSheet extends ConsumerStatefulWidget {
  final DateTime initialDate;
  final TimeOfDay? initialStartTime;
  const _AddSessionSheet({required this.initialDate, this.initialStartTime});
  @override
  ConsumerState<_AddSessionSheet> createState() => _AddSessionSheetState();
}

class _AddSessionSheetState extends ConsumerState<_AddSessionSheet> {
  String? _courseTypeId;
  String? _locationId;
  late DateTime _date = widget.initialDate;
  late TimeOfDay _startTime =
      widget.initialStartTime ?? const TimeOfDay(hour: 9, minute: 0);
  final _duration = TextEditingController(text: '240');
  final _capacity = TextEditingController(text: '4');
  final Set<String> _instructorIds = <String>{};
  bool _saving = false;
  String? _error;
  String? _warning;

  @override
  void dispose() {
    _duration.dispose();
    _capacity.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickStart() async {
    final picked = await showTimePicker(context: context, initialTime: _startTime);
    if (picked != null) setState(() => _startTime = picked);
  }

  Future<void> _submit() async {
    if (_courseTypeId == null || _locationId == null) {
      setState(() => _error = 'Pick a course and a location.');
      return;
    }
    final dur = int.tryParse(_duration.text);
    final cap = int.tryParse(_capacity.text);
    if (dur == null || dur <= 0 || cap == null || cap <= 0) {
      setState(() => _error = 'Duration and capacity must be positive integers.');
      return;
    }
    final starts = DateTime(_date.year, _date.month, _date.day,
        _startTime.hour, _startTime.minute);
    final ends = starts.add(Duration(minutes: dur));
    setState(() {
      _saving = true;
      _error = null;
      _warning = null;
    });
    try {
      final res = await ref.read(apiClientProvider).createSession(
            courseTypeId: _courseTypeId!,
            locationId: _locationId!,
            startsAt: starts,
            endsAt: ends,
            capacity: cap,
            instructorIds: _instructorIds.toList(),
          );
      ref.invalidate(masterCalendarProvider);
      if (!mounted) return;
      if (res.warnings.isEmpty) {
        Navigator.pop(context);
        return;
      }
      // Soft ratio warning — surface and let the manager dismiss.
      setState(() {
        _warning = res.warnings.first;
        _saving = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not add session.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final courses = ref.watch(courseTypesProvider).valueOrNull ?? const [];
    final locations = ref.watch(locationsProvider).valueOrNull ?? const [];
    final instructors = ref.watch(instructorsProvider).valueOrNull ?? const [];
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4,
                    width: 36,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: KsColors.border2,
                      borderRadius: BorderRadius.circular(KsRadius.pill),
                    ),
                  ),
                ),
                Text('Add session',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink)),
                const SizedBox(height: 4),
                const Text(
                  'Instructors are optional — leave blank to scaffold the schedule and assign people later.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12),
                ),
                const SizedBox(height: 14),
                _label('Course'),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final c in courses)
                    _picker(
                      label: c.code,
                      selected: _courseTypeId == c.id,
                      onTap: () => setState(() => _courseTypeId = c.id),
                    ),
                ]),
                const SizedBox(height: 12),
                _label('Location'),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final l in locations)
                    _picker(
                      label: l.name,
                      selected: _locationId == l.id,
                      onTap: () => setState(() => _locationId = l.id),
                    ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: Text(DateFormat('EEE d MMM').format(_date)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickStart,
                      icon: const Icon(Icons.access_time, size: 16),
                      label: Text('Start ${_startTime.format(context)}'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _duration,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Duration (min)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _capacity,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Capacity',
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 14),
                _label('Instructors (optional)'),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final i in instructors)
                    _picker(
                      label: i.name,
                      selected: _instructorIds.contains(i.userId),
                      onTap: () => setState(() {
                        if (_instructorIds.contains(i.userId)) {
                          _instructorIds.remove(i.userId);
                        } else {
                          _instructorIds.add(i.userId);
                        }
                      }),
                    ),
                ]),
                if (_warning != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: KsColors.warningTint,
                      borderRadius: BorderRadius.circular(KsRadius.md),
                      border: Border.all(
                          color: KsColors.warning.withValues(alpha: 0.5)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: KsColors.warning),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(_warning!,
                              style: const TextStyle(
                                  color: KsColors.ink2, fontSize: 12.5))),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Session has been created. Close this dialog or keep editing.',
                    style: TextStyle(color: KsColors.ink3, fontSize: 11.5),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: KsColors.dangerTint,
                      borderRadius: BorderRadius.circular(KsRadius.md),
                    ),
                    child: Text(_error!,
                        style: const TextStyle(color: KsColors.danger)),
                  ),
                ],
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: _saving ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5))
                      : Text(_warning == null ? 'Add session' : 'Close'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: GoogleFonts.plusJakartaSans(
                color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 13)),
      );

  Widget _picker({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? KsColors.primaryTint : KsColors.surface2,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(
            color: selected
                ? KsColors.primary.withValues(alpha: 0.5)
                : KsColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(label,
            style: TextStyle(
              color: selected ? KsColors.primaryDeep : KsColors.ink2,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            )),
      ),
    );
  }
}
