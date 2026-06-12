// Admin Closures — school-wide closed dates (bank holidays, snow,
// instructor sickness). Sessions can't be created on these days; the
// template materialiser silently skips them.
//
// The "N sessions on this date" warning lets the manager spot
// already-scheduled sessions that fall inside a newly-created
// closure — they're not auto-cancelled (that would surprise students)
// but the warning nudges the manager to use bulk cancel on the
// calendar.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

final closuresProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.read(apiClientProvider).listClosures();
});

class AdminClosuresScreen extends ConsumerWidget {
  const AdminClosuresScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(closuresProvider);
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(closuresProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Closures',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: KsColors.ink,
                            letterSpacing: -0.6)),
                    const SizedBox(height: 4),
                    const Text(
                      'Bank holidays, snow days, instructor sickness. Sessions can\'t be created on these dates.',
                      style: TextStyle(color: KsColors.ink3, fontSize: 13),
                    ),
                  ]),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: () => _showAddClosureSheet(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add closure'),
            ),
          ]),
          const SizedBox(height: 18),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                  child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => KsEmptyState.error(
              title: 'Couldn’t load closures',
              message: e.toString(),
            ),
            data: (list) {
              if (list.isEmpty) {
                return const KsEmptyState(
                  icon: Icons.event_busy_outlined,
                  title: 'No closures set',
                  message:
                      'Add one for each day the school is closed. Bank holidays, weather days, anything you don\'t want sessions scheduled on.',
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
                    _ClosureRow(row: list[i], last: i == list.length - 1),
                ]),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ClosureRow extends ConsumerStatefulWidget {
  final Map<String, dynamic> row;
  final bool last;
  const _ClosureRow({required this.row, required this.last});
  @override
  ConsumerState<_ClosureRow> createState() => _ClosureRowState();
}

class _ClosureRowState extends ConsumerState<_ClosureRow> {
  bool _busy = false;

  Future<void> _delete() async {
    final id = (widget.row['id'] ?? '') as String;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this closure?'),
        content: const Text(
            'Sessions on this date can be created again afterwards. Existing sessions on the date are unaffected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove',
                style: TextStyle(color: KsColors.danger)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).deleteClosure(id);
      ref.invalidate(closuresProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not remove: $e'),
        backgroundColor: KsColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final fromDate = (r['fromDate'] ?? '') as String;
    final toDate = (r['toDate'] ?? '') as String;
    final label = (r['label'] ?? '') as String;
    final reason = (r['reason'] ?? '') as String;
    final affected = (r['sessionsAffected'] as num?)?.toInt() ?? 0;
    final df = DateFormat('EEE d MMM yyyy');
    final fromParsed = DateTime.tryParse(fromDate);
    final toParsed = DateTime.tryParse(toDate);
    final dateLabel = (fromParsed != null && toParsed != null)
        ? (fromDate == toDate
            ? df.format(fromParsed)
            : '${df.format(fromParsed)} → ${df.format(toParsed)}')
        : (fromDate == toDate ? fromDate : '$fromDate → $toDate');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: widget.last
              ? BorderSide.none
              : const BorderSide(color: KsColors.border),
        ),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: KsColors.dangerTint,
            borderRadius: BorderRadius.circular(KsRadius.sm),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.event_busy_outlined,
              color: KsColors.danger, size: 20),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: KsColors.ink)),
            const SizedBox(height: 2),
            Text(dateLabel,
                style:
                    const TextStyle(color: KsColors.ink3, fontSize: 12.5)),
            if (reason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(reason,
                    style:
                        const TextStyle(color: KsColors.ink3, fontSize: 12)),
              ),
            if (affected > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: KsColors.warningTint,
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                  ),
                  child: Text(
                      '$affected scheduled session${affected == 1 ? '' : 's'} on this date',
                      style: GoogleFonts.plusJakartaSans(
                          color: KsColors.warning,
                          fontWeight: FontWeight.w700,
                          fontSize: 11.5)),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 10),
        _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : IconButton(
                tooltip: 'Remove',
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: KsColors.ink3),
              ),
      ]),
    );
  }
}

// ---------- Add sheet ----------

Future<void> _showAddClosureSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => const _AddClosureSheet(),
  );
}

class _AddClosureSheet extends ConsumerStatefulWidget {
  const _AddClosureSheet();
  @override
  ConsumerState<_AddClosureSheet> createState() => _AddClosureSheetState();
}

class _AddClosureSheetState extends ConsumerState<_AddClosureSheet> {
  final _label = TextEditingController();
  final _reason = TextEditingController();
  DateTime? _fromDate;
  DateTime? _toDate;
  bool _multiDay = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickFrom() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fromDate ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (picked != null) {
      setState(() {
        _fromDate = picked;
        if (_toDate != null && _toDate!.isBefore(picked)) {
          _toDate = picked;
        }
      });
    }
  }

  Future<void> _pickTo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _toDate ?? _fromDate ?? DateTime.now(),
      firstDate: _fromDate ?? DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (picked != null) setState(() => _toDate = picked);
  }

  Future<void> _submit() async {
    if (_label.text.trim().isEmpty || _fromDate == null) {
      setState(() => _error = 'Pick a date and give it a label.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).createClosure(
            fromDate: _isoDate(_fromDate!),
            toDate: _multiDay && _toDate != null ? _isoDate(_toDate!) : '',
            label: _label.text.trim(),
            reason: _reason.text.trim(),
          );
      ref.invalidate(closuresProvider);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not save closure.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  Text('Add a closure',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: KsColors.ink)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _label,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      hintText: 'e.g. Christmas Day',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Switch.adaptive(
                      value: _multiDay,
                      onChanged: (v) => setState(() {
                        _multiDay = v;
                        if (!v) _toDate = null;
                      }),
                    ),
                    const SizedBox(width: 8),
                    const Text('Range of days',
                        style: TextStyle(
                            color: KsColors.ink2, fontSize: 13.5)),
                  ]),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickFrom,
                        icon: const Icon(Icons.calendar_today_outlined,
                            size: 16),
                        label: Text(_fromDate == null
                            ? (_multiDay ? 'From' : 'On')
                            : (_multiDay
                                ? 'From ${_isoDate(_fromDate!)}'
                                : _isoDate(_fromDate!))),
                      ),
                    ),
                    if (_multiDay) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickTo,
                          icon: const Icon(Icons.calendar_today_outlined,
                              size: 16),
                          label: Text(_toDate == null
                              ? 'Until'
                              : 'Until ${_isoDate(_toDate!)}'),
                        ),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reason,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Reason (optional)',
                      hintText: 'e.g. Snow warning · all of Northern Ireland',
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
                        : const Text('Add closure'),
                  ),
                ]),
          ),
        ),
      ),
    );
  }
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
