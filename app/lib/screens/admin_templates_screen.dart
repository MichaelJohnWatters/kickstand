// Admin Session Templates — recurring schedule recipes.
//
// One row per template ("every Saturday 09:00 CBT-125, Belfast, Dave,
// capacity 4"). "Materialise" sweeps the next N weeks and generates
// concrete sessions for every template. Idempotent.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

final sessionTemplatesProvider =
    FutureProvider.autoDispose<List<SessionTemplate>>((ref) async {
  return ref.read(apiClientProvider).listSessionTemplates();
});

/// Selected window for the "Generate" action — drives the chips below
/// the header.
final _materialiseWeeksProvider =
    StateProvider.autoDispose<int>((_) => 4);

/// Recent materialisation passes for the history list.
final materialisationsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  return ref.read(apiClientProvider).listMaterialisations();
});

/// Whether the history list is showing everything or just the head.
/// Default collapsed because the common-case viewer only cares about
/// the most recent few passes.
final _materialisationsExpandedProvider =
    StateProvider.autoDispose<bool>((_) => false);
const _materialisationsCollapsedLimit = 5;

/// Preview the count of NEW sessions one template would generate in the
/// next 4 weeks. Family-keyed by template id so the per-row futures
/// don't trample each other.
final templatePreviewProvider =
    FutureProvider.autoDispose.family<int, String>((ref, id) async {
  return ref.read(apiClientProvider).previewSessionTemplate(id);
});

class AdminTemplatesScreen extends ConsumerWidget {
  const AdminTemplatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sessionTemplatesProvider);
    final weeks = ref.watch(_materialiseWeeksProvider);

    Future<void> materialise() async {
      try {
        final res = await ref
            .read(apiClientProvider)
            .materialiseTemplates(weeks: weeks);
        ref.invalidate(sessionTemplatesProvider);
        ref.invalidate(templatePreviewProvider);
        ref.invalidate(materialisationsProvider);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(res.created == 0
                ? 'Already up to date — no new sessions to add.'
                : 'Generated ${res.created} session${res.created == 1 ? '' : 's'} for the next $weeks week${weeks == 1 ? '' : 's'}.'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not materialise: $e'),
            backgroundColor: KsColors.danger,
          ));
        }
      }
    }

    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async {
        ref.invalidate(sessionTemplatesProvider);
        ref.invalidate(materialisationsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Session templates',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: KsColors.ink,
                            letterSpacing: -0.6)),
                    const SizedBox(height: 4),
                    const Text(
                      'Recurring schedules. Pick a window and "Generate" to materialise the concrete sessions.',
                      style: TextStyle(color: KsColors.ink3, fontSize: 13),
                    ),
                  ]),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: () => _showCreateSheet(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New template'),
            ),
          ]),
          const SizedBox(height: 14),
          _GenerateBar(
            weeks: weeks,
            onWeeksChange: (n) =>
                ref.read(_materialiseWeeksProvider.notifier).state = n,
            onGenerate: materialise,
          ),
          const SizedBox(height: 18),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                  child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => KsEmptyState.error(message: e.toString()),
            data: (list) {
              if (list.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: KsColors.surface,
                    borderRadius: BorderRadius.circular(KsRadius.lg),
                    border: Border.all(color: KsColors.border),
                  ),
                  child: Column(children: [
                    const Icon(Icons.event_repeat_outlined,
                        size: 48, color: KsColors.ink4),
                    const SizedBox(height: 12),
                    Text('No templates yet — add one to stop scheduling sessions by hand.',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: KsColors.ink),
                        textAlign: TextAlign.center),
                  ]),
                );
              }
              return Container(
                decoration: BoxDecoration(
                  color: KsColors.surface,
                  borderRadius: BorderRadius.circular(KsRadius.lg),
                  border: Border.all(color: KsColors.border),
                  boxShadow: KsShadows.sh1,
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (var i = 0; i < list.length; i++)
                    _TemplateRow(
                      template: list[i],
                      last: i == list.length - 1,
                    ),
                ]),
              );
            },
          ),
          const SizedBox(height: 24),
          const _MaterialisationHistory(),
        ],
      ),
    );
  }
}

const _weekdayLabels = <String>[
  'Sundays', 'Mondays', 'Tuesdays', 'Wednesdays',
  'Thursdays', 'Fridays', 'Saturdays',
];

class _TemplateRow extends ConsumerWidget {
  final SessionTemplate template;
  final bool last;
  const _TemplateRow({required this.template, required this.last});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> generateThis() async {
      final weeks = ref.read(_materialiseWeeksProvider);
      try {
        final res = await ref
            .read(apiClientProvider)
            .materialiseOneTemplate(template.id, weeks: weeks);
        ref.invalidate(sessionTemplatesProvider);
        ref.invalidate(templatePreviewProvider(template.id));
        ref.invalidate(materialisationsProvider);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(res.created == 0
                ? 'Already up to date for ${template.courseCode}.'
                : 'Generated ${res.created} session${res.created == 1 ? '' : 's'} of ${template.courseCode} for the next $weeks week${weeks == 1 ? '' : 's'}.'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not generate: $e'),
            backgroundColor: KsColors.danger,
          ));
        }
      }
    }

    Future<void> delete() async {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete template?'),
          content: const Text(
              'Sessions already generated from this template will remain on the calendar. New sessions stop being generated.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: KsColors.danger)),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      try {
        await ref.read(apiClientProvider).deleteSessionTemplate(template.id);
        ref.invalidate(sessionTemplatesProvider);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not delete: $e'),
            backgroundColor: KsColors.danger,
          ));
        }
      }
    }

    final duration = template.durationMinutes >= 60
        ? '${(template.durationMinutes / 60).toStringAsFixed(template.durationMinutes % 60 == 0 ? 0 : 1)}h'
        : '${template.durationMinutes}m';
    final preview = ref.watch(templatePreviewProvider(template.id));
    final weeks = ref.watch(_materialiseWeeksProvider);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: last
              ? BorderSide.none
              : const BorderSide(color: KsColors.border),
        ),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                '${_weekdayLabels[template.weekday]} · ${template.startsAtTime} · ${template.courseCode}',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: KsColors.ink)),
            const SizedBox(height: 2),
            Text(
                '${template.courseName} · ${template.locationName} · ${template.instructorName} · capacity ${template.capacity} · $duration',
                style:
                    const TextStyle(color: KsColors.ink3, fontSize: 12.5)),
            if (template.startsOn.isNotEmpty || template.endsOn.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _rangeLabel(template.startsOn, template.endsOn),
                  style: const TextStyle(color: KsColors.ink3, fontSize: 12),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 8),
        _PreviewPill(preview: preview),
        OutlinedButton.icon(
          onPressed: generateThis,
          icon: const Icon(Icons.event_available_outlined, size: 14),
          label: Text('Generate ${weeks}w'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            textStyle: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ),
        IconButton(
          tooltip: 'Delete',
          onPressed: delete,
          icon: const Icon(Icons.delete_outline,
              size: 18, color: KsColors.ink3),
        ),
      ]),
    );
  }

  String _rangeLabel(String start, String end) {
    if (start.isNotEmpty && end.isNotEmpty) return 'Runs $start → $end';
    if (start.isNotEmpty) return 'Starts $start';
    return 'Ends $end';
  }
}

/// Shows how many NEW sessions the next "Generate next 4 weeks" pass
/// would create for one template. Renders as a small pill so you can
/// see at a glance whether a template still has work to do.
class _PreviewPill extends StatelessWidget {
  final AsyncValue<int> preview;
  const _PreviewPill({required this.preview});

  @override
  Widget build(BuildContext context) {
    return preview.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6),
        child: SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5)),
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (n) {
        final caughtUp = n == 0;
        final fg = caughtUp ? KsColors.ink3 : KsColors.primaryDeep;
        final bg = caughtUp ? KsColors.surface3 : KsColors.primaryTint;
        final label = caughtUp
            ? '4w · caught up'
            : '4w · +$n new';
        return Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(KsRadius.pill),
          ),
          child: Text(label,
              style: GoogleFonts.plusJakartaSans(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: 11.5)),
        );
      },
    );
  }
}

// ---------- Create sheet ----------

Future<void> _showCreateSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => const _CreateTemplateSheet(),
  );
}

class _CreateTemplateSheet extends ConsumerStatefulWidget {
  const _CreateTemplateSheet();
  @override
  ConsumerState<_CreateTemplateSheet> createState() =>
      _CreateTemplateSheetState();
}

class _CreateTemplateSheetState extends ConsumerState<_CreateTemplateSheet> {
  String? _courseTypeId;
  String? _instructorId;
  String? _locationId;
  int _weekday = 6; // Saturday
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  final _duration = TextEditingController(text: '240');
  final _capacity = TextEditingController(text: '4');
  DateTime? _startsOn;
  DateTime? _endsOn;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _duration.dispose();
    _capacity.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final picked =
        await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _pickStart() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _startsOn ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (picked != null) setState(() => _startsOn = picked);
  }

  Future<void> _pickEnd() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _endsOn ?? now.add(const Duration(days: 90)),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (picked != null) setState(() => _endsOn = picked);
  }

  Future<void> _submit() async {
    if (_courseTypeId == null || _locationId == null) {
      setState(() => _error = 'Course and location are required.');
      return;
    }
    final dur = int.tryParse(_duration.text);
    final cap = int.tryParse(_capacity.text);
    if (dur == null || dur <= 0 || cap == null || cap <= 0) {
      setState(() => _error = 'Duration and capacity must be positive integers.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).createSessionTemplate(
            courseTypeId: _courseTypeId!,
            instructorId: _instructorId ?? '',
            locationId: _locationId!,
            weekday: _weekday,
            startsAtTime:
                '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
            durationMinutes: dur,
            capacity: cap,
            startsOn: _startsOn == null ? '' : _isoDate(_startsOn!),
            endsOn: _endsOn == null ? '' : _isoDate(_endsOn!),
          );
      ref.invalidate(sessionTemplatesProvider);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not save template.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final courses = ref.watch(courseTypesProvider).valueOrNull ?? const [];
    final instructors = ref.watch(instructorsProvider).valueOrNull ?? const [];
    final locations = ref.watch(locationsProvider).valueOrNull ?? const [];
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
                  Text('New session template',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: KsColors.ink)),
                  const SizedBox(height: 16),

                  _label('Course'),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final c in courses)
                      _chip(c.code, selected: _courseTypeId == c.id,
                          onTap: () => setState(() => _courseTypeId = c.id)),
                  ]),
                  const SizedBox(height: 14),

                  _label('Instructor'),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    // Explicit "Unassigned" chip — the backend supports
                    // templates without a primary instructor (set when
                    // the session is materialised). Picking this means
                    // generated sessions surface in the calendar as
                    // "Needs instructor" so the manager can assign later.
                    _chip('Unassigned',
                        selected: _instructorId == null,
                        onTap: () => setState(() => _instructorId = null)),
                    for (final i in instructors)
                      _chip(i.name, selected: _instructorId == i.userId,
                          onTap: () => setState(() => _instructorId = i.userId)),
                  ]),
                  const SizedBox(height: 14),

                  _label('Location'),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final l in locations)
                      _chip(l.name, selected: _locationId == l.id,
                          onTap: () => setState(() => _locationId = l.id)),
                  ]),
                  const SizedBox(height: 14),

                  _label('Weekday'),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (var i = 0; i < 7; i++)
                      _chip(_weekdayLabels[i],
                          selected: _weekday == i,
                          onTap: () => setState(() => _weekday = i)),
                  ]),
                  const SizedBox(height: 14),

                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickTime,
                        icon: const Icon(Icons.access_time, size: 16),
                        label: Text('Starts at ${_time.format(context)}'),
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

                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickStart,
                        icon: const Icon(Icons.calendar_today_outlined, size: 16),
                        label: Text(_startsOn == null
                            ? 'Starts (optional)'
                            : 'From ${_isoDate(_startsOn!)}'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickEnd,
                        icon: const Icon(Icons.calendar_today_outlined, size: 16),
                        label: Text(_endsOn == null
                            ? 'Until (optional)'
                            : 'Until ${_isoDate(_endsOn!)}'),
                      ),
                    ),
                  ]),

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
                        : const Text('Add template'),
                  ),
                ]),
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

  Widget _chip(String label,
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

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

// ---------- Generate bar (weeks selector + button) ----------

const _weekOptions = <int>[1, 2, 4, 8, 12, 26];

class _GenerateBar extends StatelessWidget {
  final int weeks;
  final ValueChanged<int> onWeeksChange;
  final VoidCallback onGenerate;
  const _GenerateBar({
    required this.weeks,
    required this.onWeeksChange,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Text('Window',
            style: GoogleFonts.plusJakartaSans(
                color: KsColors.ink2,
                fontWeight: FontWeight.w700,
                fontSize: 13)),
        const SizedBox(width: 12),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final w in _weekOptions)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () => onWeeksChange(w),
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: w == weeks
                            ? KsColors.primary
                            : KsColors.surface2,
                        borderRadius: BorderRadius.circular(KsRadius.pill),
                        border: Border.all(
                          color: w == weeks
                              ? KsColors.primary
                              : KsColors.border,
                        ),
                      ),
                      child: Text('$w week${w == 1 ? '' : 's'}',
                          style: TextStyle(
                            color: w == weeks
                                ? Colors.white
                                : KsColors.ink2,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          )),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: onGenerate,
          icon: const Icon(Icons.event_available_outlined, size: 16),
          label: Text('Generate ${weeks}w'),
        ),
      ]),
    );
  }
}

// ---------- Materialisation history ----------

class _MaterialisationHistory extends ConsumerWidget {
  const _MaterialisationHistory();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(materialisationsProvider);
    final expanded = ref.watch(_materialisationsExpandedProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final showCount = expanded
            ? list.length
            : (list.length < _materialisationsCollapsedLimit
                ? list.length
                : _materialisationsCollapsedLimit);
        final hidden = list.length - showCount;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('RECENT GENERATIONS',
              style: GoogleFonts.plusJakartaSans(
                  color: KsColors.ink3,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: KsColors.surface,
              borderRadius: BorderRadius.circular(KsRadius.lg),
              border: Border.all(color: KsColors.border),
              boxShadow: KsShadows.sh1,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (var i = 0; i < showCount; i++)
                _MaterialisationRow(
                  row: list[i],
                  // The toggle row sits beneath the table when there's
                  // more to show; in that case the visible-last item
                  // shouldn't hide its border.
                  last: i == showCount - 1 && hidden == 0,
                ),
              if (hidden > 0 || expanded)
                _ExpandToggleRow(
                  expanded: expanded,
                  hidden: hidden,
                  onTap: () => ref
                      .read(_materialisationsExpandedProvider.notifier)
                      .state = !expanded,
                ),
            ]),
          ),
        ]);
      },
    );
  }
}

class _ExpandToggleRow extends StatelessWidget {
  final bool expanded;
  final int hidden;
  final VoidCallback onTap;
  const _ExpandToggleRow({
    required this.expanded,
    required this.hidden,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        alignment: Alignment.center,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 18, color: KsColors.primary),
          const SizedBox(width: 4),
          Text(
              expanded
                  ? 'Show fewer'
                  : 'Show all${hidden > 0 ? ' ($hidden more)' : ''}',
              style: GoogleFonts.plusJakartaSans(
                  color: KsColors.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 13)),
        ]),
      ),
    );
  }
}

class _MaterialisationRow extends ConsumerStatefulWidget {
  final Map<String, dynamic> row;
  final bool last;
  const _MaterialisationRow({required this.row, required this.last});
  @override
  ConsumerState<_MaterialisationRow> createState() =>
      _MaterialisationRowState();
}

class _MaterialisationRowState extends ConsumerState<_MaterialisationRow> {
  bool _busy = false;

  Future<void> _undo() async {
    final id = (widget.row['id'] ?? '') as String;
    if (id.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Undo this generation?'),
        content: const Text(
            'Deletes every session this pass created. Refuses if any session already has a booking.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Undo',
                style: TextStyle(color: KsColors.danger)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      final deleted = await ref.read(apiClientProvider).undoMaterialisation(id);
      // Undo deletes the generated sessions but leaves templates alone;
      // refresh the history list + the preview pills (which now have
      // more potential work) and don't touch the templates list.
      ref.invalidate(materialisationsProvider);
      ref.invalidate(templatePreviewProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Deleted $deleted session${deleted == 1 ? '' : 's'}.'),
        behavior: SnackBarBehavior.floating,
      ));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.code == 'has_bookings'
            ? 'Cannot undo — some sessions already have bookings. Cancel those first.'
            : 'Could not undo: ${e.message}'),
        backgroundColor: KsColors.danger,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not undo: $e'),
        backgroundColor: KsColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final undone = (r['undone'] ?? false) as bool;
    final atRaw = (r['at'] ?? '') as String;
    final at = DateTime.tryParse(atRaw)?.toLocal();
    final atLabel = at == null
        ? atRaw
        : DateFormat('d MMM HH:mm').format(at);
    final weeks = (r['weeks'] as num?)?.toInt() ?? 0;
    final created = (r['createdCount'] as num?)?.toInt() ?? 0;
    final performer = (r['performerName'] ?? '') as String;
    final from = (r['windowFrom'] ?? '') as String;
    final to = (r['windowTo'] ?? '') as String;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: widget.last
              ? BorderSide.none
              : const BorderSide(color: KsColors.border),
        ),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('+$created session${created == 1 ? '' : 's'}',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: undone ? KsColors.ink3 : KsColors.ink,
                      decoration: undone ? TextDecoration.lineThrough : null)),
              const SizedBox(width: 8),
              if (undone)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: KsColors.surface3,
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                  ),
                  child: Text('UNDONE',
                      style: GoogleFonts.plusJakartaSans(
                          color: KsColors.ink3,
                          fontWeight: FontWeight.w800,
                          fontSize: 10,
                          letterSpacing: 0.5)),
                ),
            ]),
            const SizedBox(height: 2),
            Text(
                '$weeks-week window · $from → $to · by ${performer.isEmpty ? "?" : performer} · $atLabel',
                style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
          ]),
        ),
        if (!undone)
          _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : OutlinedButton.icon(
                  onPressed: _undo,
                  icon: const Icon(Icons.undo, size: 14),
                  label: const Text('Undo'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: KsColors.danger,
                    side: const BorderSide(color: KsColors.border),
                  ),
                ),
      ]),
    );
  }
}
