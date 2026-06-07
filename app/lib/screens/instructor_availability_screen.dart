// Instructor availability — weekly recurring slots + time-off windows.
//
// Layout:
//   - Sticky day cards (Mon–Sun) with their slots as chips
//   - Per-day "+" affordance opens add-slot sheet
//   - Tap a slot chip → delete confirmation
//   - Section below for time-off, with add and per-row delete
//
// The instructor sees their own; admin sees the same screen pointed at any
// instructor (deferred — for now we just use the caller's own id).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/notification_bell.dart';

// Family-keyed by instructor id. Non-autoDispose so the ambient refresh
// observer can invalidate the whole family on its timer and keep the
// cached value painted while the new future resolves.
final availabilitySlotsProvider =
    FutureProvider.family<List<RecurringSlot>, String>((ref, instructorId) async {
  return ref.read(apiClientProvider).listRecurringSlots(instructorId);
});

final availabilityTimeOffProvider =
    FutureProvider.family<List<TimeOff>, String>((ref, instructorId) async {
  return ref.read(apiClientProvider).listTimeOff(instructorId);
});

const _weekdayNames = [
  'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
];

class InstructorAvailabilityScreen extends ConsumerWidget {
  const InstructorAvailabilityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authControllerProvider).identity;
    if (me == null) {
      return const Scaffold(body: SizedBox.shrink());
    }
    final id = me.userId;
    final slotsAsync = ref.watch(availabilitySlotsProvider(id));
    final timeOffAsync = ref.watch(availabilityTimeOffProvider(id));

    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: Text('Availability',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: const [NotificationBell()],
      ),
      body: RefreshIndicator(
        color: KsColors.primary,
        onRefresh: () async {
          ref.invalidate(availabilitySlotsProvider(id));
          ref.invalidate(availabilityTimeOffProvider(id));
        },
        child: slotsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator(color: KsColors.primary)),
          error: (e, _) => ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('Couldn’t load.\n$e'))]),
          data: (slots) {
            // Group slots by weekday (0..6).
            final byDay = <int, List<RecurringSlot>>{};
            for (final s in slots) {
              byDay.putIfAbsent(s.weekday, () => []).add(s);
            }
            for (final list in byDay.values) {
              list.sort((a, b) => a.startsAtLocal.compareTo(b.startsAtLocal));
            }
            // Render Mon..Sun (weekday indices 1..6 then 0).
            const displayOrder = [1, 2, 3, 4, 5, 6, 0];
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Weekly availability',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 16, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.3)),
                const SizedBox(height: 4),
                const Text('Recurring hours you offer.',
                    style: TextStyle(color: KsColors.ink3, fontSize: 12)),
                const SizedBox(height: 10),
                ...displayOrder.map((weekday) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _DayCard(
                        weekday: weekday,
                        slots: byDay[weekday] ?? const [],
                        instructorId: id,
                      ),
                    )),
                const SizedBox(height: 20),
                Row(children: [
                  Text('Time off',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 16, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.3)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _showAddTimeOffSheet(context, ref, id),
                    icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                    label: const Text('Add'),
                  ),
                ]),
                const SizedBox(height: 4),
                const Text('Holidays, training days, anything blocking sessions.',
                    style: TextStyle(color: KsColors.ink3, fontSize: 12)),
                const SizedBox(height: 10),
                timeOffAsync.when(
                  loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: CircularProgressIndicator(color: KsColors.primary))),
                  error: (e, _) => Text('Couldn’t load time off.\n$e'),
                  data: (off) => off.isEmpty
                      ? Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: KsColors.surface2,
                            borderRadius: BorderRadius.circular(KsRadius.md),
                            border: Border.all(color: KsColors.border),
                          ),
                          child: const Text('No time off booked.', style: TextStyle(color: KsColors.ink2)),
                        )
                      : Column(
                          children: off.map((t) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _TimeOffRow(timeOff: t, instructorId: id),
                              )).toList(),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DayCard extends ConsumerWidget {
  final int weekday;
  final List<RecurringSlot> slots;
  final String instructorId;
  const _DayCard({required this.weekday, required this.slots, required this.instructorId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(_weekdayNames[weekday],
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 15)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _showAddSlotSheet(context, ref, instructorId, weekday),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add slot'),
            ),
          ]),
          if (slots.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('No slots offered.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 13)),
            )
          else
            Wrap(
              spacing: 8, runSpacing: 8,
              children: slots.map((s) => _SlotChip(slot: s, instructorId: instructorId)).toList(),
            ),
        ],
      ),
    );
  }
}

class _SlotChip extends ConsumerStatefulWidget {
  final RecurringSlot slot;
  final String instructorId;
  const _SlotChip({required this.slot, required this.instructorId});

  @override
  ConsumerState<_SlotChip> createState() => _SlotChipState();
}

class _SlotChipState extends ConsumerState<_SlotChip> {
  bool _deleting = false;

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete slot?'),
        content: Text('${widget.slot.startsAtLocal}–${widget.slot.endsAtLocal} on ${_weekdayNames[widget.slot.weekday]}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: KsColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _deleting = true);
    try {
      await ref.read(apiClientProvider).deleteRecurringSlot(widget.slot.id);
      ref.invalidate(availabilitySlotsProvider(widget.instructorId));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not delete'),
          backgroundColor: KsColors.danger,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locations = ref.watch(locationsProvider).valueOrNull ?? const [];
    final locName = widget.slot.locationId.isEmpty
        ? ''
        : (locations.firstWhere((l) => l.id == widget.slot.locationId,
                orElse: () => LocationLite(id: '', name: '', address: '')).name);
    return InkWell(
      onTap: _deleting ? null : _delete,
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: KsColors.primaryTint,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(color: KsColors.primary.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${widget.slot.startsAtLocal}–${widget.slot.endsAtLocal}',
                style: const TextStyle(
                    color: KsColors.primaryDeep, fontWeight: FontWeight.w700, fontSize: 13)),
            if (locName.isNotEmpty) ...[
              const SizedBox(width: 6),
              Container(width: 3, height: 3, decoration: const BoxDecoration(color: KsColors.primary, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(locName,
                  style: const TextStyle(color: KsColors.primaryDeep, fontWeight: FontWeight.w600, fontSize: 12)),
            ],
            const SizedBox(width: 6),
            _deleting
                ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(color: KsColors.primaryDeep, strokeWidth: 1.5))
                : const Icon(Icons.close, size: 14, color: KsColors.primaryDeep),
          ],
        ),
      ),
    );
  }
}

class _TimeOffRow extends ConsumerStatefulWidget {
  final TimeOff timeOff;
  final String instructorId;
  const _TimeOffRow({required this.timeOff, required this.instructorId});

  @override
  ConsumerState<_TimeOffRow> createState() => _TimeOffRowState();
}

class _TimeOffRowState extends ConsumerState<_TimeOffRow> {
  bool _deleting = false;

  Future<void> _delete() async {
    setState(() => _deleting = true);
    try {
      await ref.read(apiClientProvider).deleteTimeOff(widget.timeOff.id);
      ref.invalidate(availabilityTimeOffProvider(widget.instructorId));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not delete'),
          backgroundColor: KsColors.danger,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('EEE d MMM');
    final t = widget.timeOff;
    final sameDay = t.startsAt.year == t.endsAt.year &&
        t.startsAt.month == t.endsAt.month &&
        t.startsAt.day == t.endsAt.day;
    final rangeLabel = sameDay
        ? df.format(t.startsAt)
        : '${df.format(t.startsAt)} – ${df.format(t.endsAt)}';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.md),
        border: Border.all(color: KsColors.border),
      ),
      child: Row(children: [
        const Icon(Icons.event_busy_outlined, color: KsColors.warning, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rangeLabel,
                  style: GoogleFonts.plusJakartaSans(
                      color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 14)),
              if (t.reason.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(t.reason, style: const TextStyle(color: KsColors.ink2, fontSize: 12)),
                ),
            ],
          ),
        ),
        IconButton(
          onPressed: _deleting ? null : _delete,
          icon: _deleting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: KsColors.ink3, strokeWidth: 2))
              : const Icon(Icons.delete_outline, color: KsColors.ink3, size: 20),
        ),
      ]),
    );
  }
}

// ----- Sheets -----

Future<void> _showAddSlotSheet(BuildContext context, WidgetRef ref, String instructorId, int weekday) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _AddSlotSheet(instructorId: instructorId, weekday: weekday),
  );
}

class _AddSlotSheet extends ConsumerStatefulWidget {
  final String instructorId;
  final int weekday;
  const _AddSlotSheet({required this.instructorId, required this.weekday});
  @override
  ConsumerState<_AddSlotSheet> createState() => _AddSlotSheetState();
}

class _AddSlotSheetState extends ConsumerState<_AddSlotSheet> {
  TimeOfDay _start = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 13, minute: 0);
  String? _locationId;
  bool _saving = false;
  String? _error;

  String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickTime(bool start) async {
    final res = await showTimePicker(
      context: context,
      initialTime: start ? _start : _end,
    );
    if (res != null) setState(() => start ? _start = res : _end = res);
  }

  Future<void> _submit() async {
    if (_hhmm(_start).compareTo(_hhmm(_end)) >= 0) {
      setState(() => _error = 'End time must be after start time.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).createRecurringSlot(
            instructorId: widget.instructorId,
            weekday: widget.weekday,
            startsAtLocal: _hhmm(_start),
            endsAtLocal: _hhmm(_end),
            locationId: _locationId,
          );
      ref.invalidate(availabilitySlotsProvider(widget.instructorId));
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not save.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locations = ref.watch(locationsProvider).valueOrNull ?? const [];
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  height: 4, width: 36,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: KsColors.border2,
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                  ),
                ),
              ),
              Text('Add ${_weekdayNames[widget.weekday]} slot',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 18, fontWeight: FontWeight.w800, color: KsColors.ink)),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(child: _TimeButton(label: 'Start', value: _hhmm(_start), onTap: () => _pickTime(true))),
                const SizedBox(width: 10),
                Expanded(child: _TimeButton(label: 'End', value: _hhmm(_end), onTap: () => _pickTime(false))),
              ]),
              const SizedBox(height: 14),
              if (locations.isNotEmpty) ...[
                Text('Location (optional)',
                    style: GoogleFonts.plusJakartaSans(
                        color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8, runSpacing: 8,
                  children: [
                    _LocChip(label: 'Any', selected: _locationId == null, onTap: () => setState(() => _locationId = null)),
                    ...locations.map((l) => _LocChip(
                          label: l.name,
                          selected: _locationId == l.id,
                          onTap: () => setState(() => _locationId = l.id),
                        )),
                  ],
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
                  child: Text(_error!, style: const TextStyle(color: KsColors.danger)),
                ),
              ],
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Text('Save slot'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeButton extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;
  const _TimeButton({required this.label, required this.value, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: KsColors.surface2,
          borderRadius: BorderRadius.circular(KsRadius.md),
          border: Border.all(color: KsColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: KsColors.ink3, fontSize: 11, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(value,
                style: GoogleFonts.plusJakartaSans(
                    color: KsColors.ink, fontWeight: FontWeight.w800, fontSize: 17)),
          ],
        ),
      ),
    );
  }
}

class _LocChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _LocChip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? KsColors.primaryTint : KsColors.surface2,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(
            color: selected ? KsColors.primary.withValues(alpha: 0.5) : KsColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(label,
            style: TextStyle(
              color: selected ? KsColors.primaryDeep : KsColors.ink2,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            )),
      ),
    );
  }
}

// ----- Time-off sheet -----

Future<void> _showAddTimeOffSheet(BuildContext context, WidgetRef ref, String instructorId) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _AddTimeOffSheet(instructorId: instructorId),
  );
}

class _AddTimeOffSheet extends ConsumerStatefulWidget {
  final String instructorId;
  const _AddTimeOffSheet({required this.instructorId});
  @override
  ConsumerState<_AddTimeOffSheet> createState() => _AddTimeOffSheetState();
}

class _AddTimeOffSheetState extends ConsumerState<_AddTimeOffSheet> {
  late DateTime _start;
  late DateTime _end;
  final _reasonCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _start = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    _end = _start.add(const Duration(days: 1));
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool start) async {
    final res = await showDatePicker(
      context: context,
      initialDate: start ? _start : _end,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (res == null) return;
    setState(() {
      if (start) {
        _start = res;
        if (!_end.isAfter(_start)) _end = _start.add(const Duration(days: 1));
      } else {
        _end = res;
      }
    });
  }

  Future<void> _submit() async {
    if (!_end.isAfter(_start)) {
      setState(() => _error = 'End date must be after start date.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).createTimeOff(
            instructorId: widget.instructorId,
            startsAt: _start,
            endsAt: _end,
            reason: _reasonCtrl.text.trim().isEmpty ? null : _reasonCtrl.text.trim(),
          );
      ref.invalidate(availabilityTimeOffProvider(widget.instructorId));
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not save.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('EEE d MMM yyyy');
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  height: 4, width: 36,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: KsColors.border2,
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                  ),
                ),
              ),
              Text('Add time off',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 18, fontWeight: FontWeight.w800, color: KsColors.ink)),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(child: _TimeButton(label: 'Start', value: df.format(_start), onTap: () => _pickDate(true))),
                const SizedBox(width: 10),
                Expanded(child: _TimeButton(label: 'End', value: df.format(_end), onTap: () => _pickDate(false))),
              ]),
              const SizedBox(height: 14),
              TextField(
                controller: _reasonCtrl,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                  hintText: 'e.g. Annual leave',
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
                  child: Text(_error!, style: const TextStyle(color: KsColors.danger)),
                ),
              ],
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
