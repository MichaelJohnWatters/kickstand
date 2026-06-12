// Admin Incidents — every open incident follow-up across the school.
//
// One row per follow-up (mechanical check / welfare call / insurance
// notify). Overdue rows surface red. Checkbox toggles done; the underlying
// list invalidates so the overview badge stays in sync.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

class AdminIncidentsScreen extends ConsumerWidget {
  const AdminIncidentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(openFollowupsProvider);
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(openFollowupsProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Incident follow-ups',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  letterSpacing: -0.6)),
          const SizedBox(height: 4),
          const Text(
            'Mechanical checks, welfare calls, insurance notifications. Tick them off as they\'re handled.',
            style: TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 18),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                  child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => KsEmptyState.error(
              title: 'Couldn’t load follow-ups',
              message: e.toString(),
            ),
            data: (p) {
              if (p.followups.isEmpty) {
                return const KsEmptyState(
                  icon: Icons.check_circle_outline,
                  title: 'All clear',
                  message:
                      'No outstanding incident follow-ups across the school.',
                  iconColour: KsColors.success,
                );
              }
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _CountStrip(open: p.open, overdue: p.overdue),
                    const SizedBox(height: 14),
                    Container(
                      decoration: BoxDecoration(
                        color: KsColors.surface,
                        borderRadius: BorderRadius.circular(KsRadius.lg),
                        border: Border.all(color: KsColors.border),
                        boxShadow: KsShadows.sh1,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(children: [
                        for (var i = 0; i < p.followups.length; i++)
                          _FollowupListRow(
                            row: p.followups[i],
                            last: i == p.followups.length - 1,
                          ),
                      ]),
                    ),
                  ]);
            },
          ),
        ],
      ),
    );
  }
}

class _CountStrip extends StatelessWidget {
  final int open;
  final int overdue;
  const _CountStrip({required this.open, required this.overdue});

  @override
  Widget build(BuildContext context) {
    Widget tile(Color tone, IconData icon, int n, String label) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: KsColors.surface,
              borderRadius: BorderRadius.circular(KsRadius.lg),
              border: Border.all(color: KsColors.border),
              boxShadow: KsShadows.sh1,
            ),
            child: Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(KsRadius.sm),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: tone, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(n.toString(),
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: KsColors.ink,
                            height: 1)),
                    const SizedBox(height: 2),
                    Text(label,
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: KsColors.ink2)),
                  ],
                ),
              ),
            ]),
          ),
        );
    return Row(children: [
      tile(KsColors.warning, Icons.schedule_rounded, open, 'Open'),
      const SizedBox(width: 12),
      tile(KsColors.danger, Icons.priority_high_rounded, overdue, 'Overdue'),
    ]);
  }
}

class _FollowupListRow extends ConsumerStatefulWidget {
  final Map<String, dynamic> row;
  final bool last;
  const _FollowupListRow({required this.row, required this.last});
  @override
  ConsumerState<_FollowupListRow> createState() => _FollowupListRowState();
}

class _FollowupListRowState extends ConsumerState<_FollowupListRow> {
  bool _busy = false;

  Future<void> _markDone() async {
    final id = (widget.row['id'] ?? '') as String;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).completeFollowup(followupId: id);
      ref.invalidate(openFollowupsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not update: $e'),
          backgroundColor: KsColors.danger,
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final kind = (r['kind'] ?? '') as String;
    final description = (r['description'] ?? '') as String;
    final dueOn = (r['dueOn'] ?? '') as String;
    final studentName = (r['studentName'] ?? '') as String;
    final studentId = (r['studentId'] ?? '') as String;
    final bikeLabel = (r['bikeLabel'] ?? '') as String;
    final incidentDesc = (r['incidentDescription'] ?? '') as String;
    final incidentAt =
        DateTime.tryParse((r['incidentOccurredAt'] ?? '') as String)?.toLocal();
    final today = DateTime.now();
    final dueParsed = DateTime.tryParse(dueOn);
    final overdue = dueParsed != null &&
        dueParsed.isBefore(DateTime(today.year, today.month, today.day));
    final kindLabel = switch (kind) {
      'mechanical_check' => 'Mechanical check',
      'student_welfare' => 'Welfare call',
      'insurance_notify' => 'Insurance notify',
      _ => 'Follow-up',
    };

    return InkWell(
      onTap: studentId.isEmpty
          ? null
          : () => context.go('/admin/students/$studentId'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: widget.last
                ? BorderSide.none
                : const BorderSide(color: KsColors.border),
          ),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : InkWell(
                  onTap: _markDone,
                  child: const Icon(
                    Icons.check_box_outline_blank_rounded,
                    color: KsColors.ink3,
                    size: 22,
                  ),
                ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(kindLabel,
                        style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: KsColors.ink)),
                    const SizedBox(width: 8),
                    if (overdue)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: KsColors.dangerTint,
                          borderRadius: BorderRadius.circular(KsRadius.pill),
                        ),
                        child: Text('Overdue · $dueOn',
                            style: GoogleFonts.plusJakartaSans(
                                color: KsColors.danger,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800)),
                      )
                    else if (dueOn.isNotEmpty)
                      Text('Due $dueOn',
                          style: const TextStyle(
                              color: KsColors.ink3, fontSize: 11)),
                  ]),
                  const SizedBox(height: 2),
                  Text(description,
                      style: const TextStyle(
                          color: KsColors.ink2, fontSize: 12.5)),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (studentName.isNotEmpty) studentName,
                      if (bikeLabel.isNotEmpty) bikeLabel,
                      if (incidentAt != null)
                        DateFormat('d MMM yyyy').format(incidentAt),
                    ].join(' · '),
                    style: const TextStyle(
                        color: KsColors.ink3,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700),
                  ),
                  if (incidentDesc.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('"$incidentDesc"',
                          style: const TextStyle(
                              color: KsColors.ink3,
                              fontStyle: FontStyle.italic,
                              fontSize: 11.5),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ),
                ]),
          ),
          const SizedBox(width: 8),
          if (studentId.isNotEmpty)
            const Icon(Icons.chevron_right_rounded,
                color: KsColors.ink4, size: 20),
        ]),
      ),
    );
  }
}
