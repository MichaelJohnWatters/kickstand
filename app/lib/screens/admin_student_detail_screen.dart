// Admin student detail — the "big manager view" from the design handoff.
//
// Single GET /students/{id} returns the full aggregate. We re-render the
// sub-trees as cards. Actions wire to existing endpoints:
//   - Record payment → RecordPaymentSheet
//   - Add charge     → simple sheet
//   - Add safety flag / progress note → simple sheet

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/record_payment_sheet.dart';
import '../widgets/empty_state.dart';

final _studentDetailProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, id) async {
  return ref.read(apiClientProvider).studentDetail(id);
});

class AdminStudentDetailScreen extends ConsumerWidget {
  final String studentId;
  const AdminStudentDetailScreen({required this.studentId, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_studentDetailProvider(studentId));
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(_studentDetailProvider(studentId)),
      child: async.when(
        loading: () => const Center(child: Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: CircularProgressIndicator(color: KsColors.primary),
        )),
        error: (e, _) => ListView(children: [Padding(padding: const EdgeInsets.all(24), child: KsEmptyState.error(message: e.toString()))]),
        data: (d) {
          final basics = (d['basics'] as Map?)?.cast<String, dynamic>() ?? const {};
          final financial = (d['financial'] as Map?)?.cast<String, dynamic>() ?? const {};
          final safetyFlags = ((d['safetyFlags'] as List?) ?? const []).cast<Map<String, dynamic>>();
          final progressNotes = ((d['notes'] as List?) ?? const []).cast<Map<String, dynamic>>();
          final tests = ((d['tests'] as List?) ?? const []).cast<Map<String, dynamic>>();
          final incidents = ((d['incidents'] as List?) ?? const []).cast<Map<String, dynamic>>();
          final progress = ((d['progress'] as List?) ?? const []).cast<Map<String, dynamic>>();

          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              _BackLink(),
              const SizedBox(height: 12),
              _Header(basics: basics, financial: financial, studentId: studentId, ref: ref),
              const SizedBox(height: 20),
              if (safetyFlags.isNotEmpty) ...[
                _SafetyFlagsCard(flags: safetyFlags, studentId: studentId, ref: ref),
                const SizedBox(height: 16),
              ],
              LayoutBuilder(builder: (ctx, c) {
                final twoCol = c.maxWidth >= 900;
                final left = [
                  _ProgressCard(progress: progress),
                  const SizedBox(height: 16),
                  _TestsCard(tests: tests),
                  const SizedBox(height: 16),
                  _IncidentsCard(incidents: incidents),
                ];
                final right = [
                  _FinancialCard(financial: financial, studentId: studentId, ref: ref),
                  const SizedBox(height: 16),
                  _NotesCard(notes: progressNotes, studentId: studentId, ref: ref),
                ];
                if (twoCol) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: Column(children: left)),
                      const SizedBox(width: 20),
                      Expanded(flex: 2, child: Column(children: right)),
                    ],
                  );
                }
                return Column(children: [...left, const SizedBox(height: 16), ...right]);
              }),
              const SizedBox(height: 24),
              _DangerZoneCard(
                studentId: studentId,
                anonymisedAt: (basics['anonymisedAt'] as String?) ?? '',
                onAnonymised: () =>
                    ref.invalidate(_studentDetailProvider(studentId)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BackLink extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go('/admin/students'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.chevron_left, color: KsColors.ink3, size: 18),
          SizedBox(width: 2),
          Text('Back to students',
              style: TextStyle(color: KsColors.ink3, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ---------------- Header ----------------

class _Header extends StatelessWidget {
  final Map<String, dynamic> basics;
  final Map<String, dynamic> financial;
  final String studentId;
  final WidgetRef ref;
  const _Header({required this.basics, required this.financial, required this.studentId, required this.ref});

  @override
  Widget build(BuildContext context) {
    final balance = (financial['balancePence'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: KsColors.primaryTint,
              borderRadius: BorderRadius.circular(KsRadius.pill),
            ),
            child: const Icon(Icons.person, color: KsColors.primaryDeep, size: 30),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(basics['name'] ?? '',
                        style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800, fontSize: 24, color: KsColors.ink, letterSpacing: -0.6)),
                  ),
                  const SizedBox(width: 10),
                  _statusBadge(basics['accountStatus'] ?? ''),
                ]),
                const SizedBox(height: 6),
                Wrap(spacing: 12, runSpacing: 6, children: [
                  _info(Icons.email_outlined, basics['email'] ?? ''),
                  if ((basics['phone'] ?? '').toString().isNotEmpty)
                    _info(Icons.phone, basics['phone']),
                  if ((basics['licenceCategoryPursued'] ?? '').toString().isNotEmpty)
                    _info(Icons.badge_outlined, 'Category ${basics['licenceCategoryPursued']}'),
                  if ((basics['transmissionPreference'] ?? '').toString().isNotEmpty)
                    _info(Icons.settings, basics['transmissionPreference']),
                ]),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('Balance',
                  style: const TextStyle(color: KsColors.ink3, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
              const SizedBox(height: 4),
              Text(_money(balance, withSign: true),
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5,
                      color: balance > 0 ? KsColors.danger : balance < 0 ? KsColors.success : KsColors.ink)),
              const SizedBox(height: 8),
              if (balance > 0)
                ElevatedButton.icon(
                  onPressed: () => RecordPaymentSheet.show(
                    context,
                    studentId: studentId,
                    studentName: basics['name'] ?? '',
                    outstandingPence: balance,
                    onRecorded: () => ref.invalidate(_studentDetailProvider(studentId)),
                  ),
                  icon: const Icon(Icons.payments_outlined, size: 18),
                  label: const Text('Record payment'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _info(IconData icon, dynamic text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: KsColors.ink3, size: 14),
          const SizedBox(width: 4),
          Text(text.toString(),
              style: const TextStyle(color: KsColors.ink2, fontSize: 13)),
        ],
      );

  Widget _statusBadge(String s) {
    late Color fg, bg;
    late String label;
    switch (s) {
      case 'active': fg = KsColors.success; bg = KsColors.successTint; label = 'Active'; break;
      case 'pending_approval': fg = KsColors.warning; bg = KsColors.warningTint; label = 'Pending'; break;
      case 'disabled': fg = KsColors.danger; bg = KsColors.dangerTint; label = 'Disabled'; break;
      default: fg = KsColors.ink3; bg = KsColors.surface3; label = s;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
      child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 11)),
    );
  }
}

// ---------------- Safety flags ----------------

class _SafetyFlagsCard extends StatelessWidget {
  final List<Map<String, dynamic>> flags;
  final String studentId;
  final WidgetRef ref;
  const _SafetyFlagsCard({required this.flags, required this.studentId, required this.ref});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KsColors.warningTint,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.warning.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.warning_amber_rounded, color: KsColors.warning, size: 20),
            const SizedBox(width: 8),
            Text('Safety & accommodation flags',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, color: KsColors.warning, fontSize: 15)),
          ]),
          const SizedBox(height: 12),
          ...flags.map((f) {
            final id = (f['id'] ?? '').toString();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                const Icon(Icons.chevron_right, color: KsColors.warning, size: 16),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(f['body'] ?? '',
                      style: const TextStyle(color: KsColors.warning, fontSize: 13.5, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: 'Deactivate',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    try {
                      await ref.read(apiClientProvider).deactivateStudentNote(id);
                      ref.invalidate(_studentDetailProvider(studentId));
                    } catch (_) {}
                  },
                  icon: const Icon(Icons.close, color: KsColors.warning),
                ),
              ]),
            );
          }),
        ],
      ),
    );
  }
}

// ---------------- Progress ----------------

class _ProgressCard extends StatelessWidget {
  final List<Map<String, dynamic>> progress;
  const _ProgressCard({required this.progress});

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Progress',
      icon: Icons.insights_rounded,
      child: progress.isEmpty
          ? const Text('No assessments recorded yet.', style: TextStyle(color: KsColors.ink3))
          : Column(
              children: progress.map((c) {
                final total = (c['totalCompetencies'] as num?)?.toInt() ?? 0;
                final competent = (c['competentCount'] as num?)?.toInt() ?? 0;
                final needs = (c['needsWorkCount'] as num?)?.toInt() ?? 0;
                final pct = total == 0 ? 0.0 : competent / total;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(c['courseName'] ?? '',
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w700, color: KsColors.ink, fontSize: 14)),
                        ),
                        Text('$competent/$total',
                            style: GoogleFonts.plusJakartaSans(
                                color: KsColors.primaryDeep, fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(KsRadius.pill),
                        child: LinearProgressIndicator(
                          value: pct,
                          minHeight: 6,
                          backgroundColor: KsColors.surface3,
                          valueColor: const AlwaysStoppedAnimation(KsColors.primary),
                        ),
                      ),
                      if (needs > 0) ...[
                        const SizedBox(height: 4),
                        Text('$needs needs work',
                            style: const TextStyle(color: KsColors.warning, fontSize: 11, fontWeight: FontWeight.w600)),
                      ],
                    ],
                  ),
                );
              }).toList(),
            ),
    );
  }
}

// ---------------- Tests ----------------

class _TestsCard extends StatelessWidget {
  final List<Map<String, dynamic>> tests;
  const _TestsCard({required this.tests});

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Test history',
      icon: Icons.fact_check_outlined,
      child: tests.isEmpty
          ? const Text('No test attempts recorded.', style: TextStyle(color: KsColors.ink3))
          : Column(
              children: tests.map((t) {
                final scheduled = DateTime.tryParse(t['scheduledAt'] ?? '')?.toLocal();
                final outcome = (t['outcome'] ?? '').toString();
                late Color fg, bg;
                late String label;
                switch (outcome) {
                  case 'pass': fg = KsColors.success; bg = KsColors.successTint; label = 'Pass'; break;
                  case 'fail': fg = KsColors.danger; bg = KsColors.dangerTint; label = 'Fail'; break;
                  case 'booked': fg = KsColors.primary; bg = KsColors.primaryTint; label = 'Booked'; break;
                  default: fg = KsColors.ink3; bg = KsColors.surface3; label = outcome;
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${_humanTestType(t['testType'] ?? '')} · attempt ${t['attemptNumber'] ?? 1}',
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w700, color: KsColors.ink, fontSize: 13)),
                          if (scheduled != null)
                            Text(DateFormat('d MMM yyyy').format(scheduled),
                                style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
                      child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 11)),
                    ),
                  ]),
                );
              }).toList(),
            ),
    );
  }

  String _humanTestType(String t) {
    switch (t) {
      case 'theory': return 'Theory';
      case 'practical': return 'Practical';
      case 'mod1': return 'Mod 1';
      case 'mod2': return 'Mod 2';
    }
    return t;
  }
}

// ---------------- Financial ----------------

class _FinancialCard extends ConsumerStatefulWidget {
  final Map<String, dynamic> financial;
  final String studentId;
  final WidgetRef ref;
  const _FinancialCard({required this.financial, required this.studentId, required this.ref});

  @override
  ConsumerState<_FinancialCard> createState() => _FinancialCardState();
}

class _FinancialCardState extends ConsumerState<_FinancialCard> {
  @override
  Widget build(BuildContext context) {
    final charged = (widget.financial['totalChargedPence'] as num?)?.toInt() ?? 0;
    final paid = (widget.financial['totalPaidPence'] as num?)?.toInt() ?? 0;
    final balance = (widget.financial['balancePence'] as num?)?.toInt() ?? 0;
    final ledger = ((widget.financial['ledger'] as List?) ?? const []).cast<Map<String, dynamic>>();

    return _Card(
      title: 'Financial',
      icon: Icons.receipt_long,
      trailing: OutlinedButton.icon(
        onPressed: () => _showAddChargeSheet(context, ref, widget.studentId),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Add charge'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _stat(label: 'Charged', value: _money(charged), colour: KsColors.ink),
            _stat(label: 'Paid', value: _money(paid), colour: KsColors.success),
            _stat(label: 'Balance', value: _money(balance, withSign: true),
                colour: balance > 0 ? KsColors.danger : balance < 0 ? KsColors.success : KsColors.ink),
          ]),
          const SizedBox(height: 14),
          if (ledger.isEmpty)
            const Text('No charges or payments yet.', style: TextStyle(color: KsColors.ink3))
          else
            Column(
              children: ledger.take(8).map((e) => _ledgerRow(e)).toList(),
            ),
        ],
      ),
    );
  }

  Widget _stat({required String label, required String value, required Color colour}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: KsColors.ink3, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
          const SizedBox(height: 4),
          Text(value,
              style: GoogleFonts.plusJakartaSans(
                  color: colour, fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: -0.3)),
        ],
      ),
    );
  }

  Widget _ledgerRow(Map<String, dynamic> e) {
    final kind = (e['kind'] ?? '').toString();
    final amount = (e['amountPence'] as num?)?.toInt() ?? 0;
    final voided = e['voided'] ?? false;
    final at = DateTime.tryParse(e['at'] ?? '')?.toLocal();
    final isPayment = kind == 'payment';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(isPayment ? Icons.arrow_circle_down : Icons.arrow_circle_up,
            size: 16,
            color: voided
                ? KsColors.ink4
                : isPayment ? KsColors.success : KsColors.danger),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isPayment ? _humanMethod(e['method'] ?? '') : (e['description'] ?? '').toString(),
                style: TextStyle(
                    color: voided ? KsColors.ink3 : KsColors.ink,
                    decoration: voided ? TextDecoration.lineThrough : null,
                    fontWeight: FontWeight.w600, fontSize: 13),
              ),
              if (at != null)
                Text(DateFormat('d MMM · HH:mm').format(at),
                    style: const TextStyle(color: KsColors.ink3, fontSize: 11)),
            ],
          ),
        ),
        Text(
          (isPayment ? '+' : '-') + _money(amount),
          style: TextStyle(
              color: voided ? KsColors.ink4 : isPayment ? KsColors.success : KsColors.danger,
              fontWeight: FontWeight.w700, fontSize: 13,
              decoration: voided ? TextDecoration.lineThrough : null),
        ),
      ]),
    );
  }

  String _humanMethod(String m) {
    switch (m) {
      case 'cash': return 'Cash';
      case 'bank_transfer': return 'Bank transfer';
      case 'card_in_person': return 'Card in person';
    }
    return m.isEmpty ? 'Payment' : m;
  }
}

// ---------------- Notes ----------------

class _NotesCard extends StatelessWidget {
  final List<Map<String, dynamic>> notes;
  final String studentId;
  final WidgetRef ref;
  const _NotesCard({required this.notes, required this.studentId, required this.ref});

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Staff notes',
      icon: Icons.sticky_note_2_outlined,
      trailing: OutlinedButton.icon(
        onPressed: () => _showAddNoteSheet(context, ref, studentId),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Add'),
      ),
      child: notes.isEmpty
          ? const Text('No notes recorded.', style: TextStyle(color: KsColors.ink3))
          : Column(
              children: notes.map((n) {
                final at = DateTime.tryParse(n['createdAt'] ?? '')?.toLocal();
                final active = n['isActive'] ?? true;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: KsColors.surface2,
                      borderRadius: BorderRadius.circular(KsRadius.md),
                      border: Border.all(color: KsColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(n['body'] ?? '',
                            style: TextStyle(
                                color: active ? KsColors.ink : KsColors.ink3,
                                decoration: active ? null : TextDecoration.lineThrough,
                                fontSize: 13)),
                        if (at != null) ...[
                          const SizedBox(height: 4),
                          Text(DateFormat('d MMM yyyy').format(at),
                              style: const TextStyle(color: KsColors.ink3, fontSize: 11)),
                        ],
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
    );
  }
}

// ---------------- Incidents ----------------

class _IncidentsCard extends StatelessWidget {
  final List<Map<String, dynamic>> incidents;
  const _IncidentsCard({required this.incidents});

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Incidents',
      icon: Icons.report_problem_outlined,
      child: incidents.isEmpty
          ? const Text('No incidents recorded.', style: TextStyle(color: KsColors.ink3))
          : Column(
              children: incidents.map((i) {
                final at = DateTime.tryParse(i['occurredAt'] ?? '')?.toLocal();
                final tookOffline = i['tookBikeOffline'] ?? false;
                final incidentId = (i['id'] ?? '') as String;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.error_outline,
                                color: KsColors.danger, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(i['description'] ?? '',
                                      style: const TextStyle(
                                          color: KsColors.ink, fontSize: 13)),
                                  const SizedBox(height: 2),
                                  Wrap(spacing: 8, children: [
                                    if (at != null)
                                      Text(DateFormat('d MMM yyyy').format(at),
                                          style: const TextStyle(
                                              color: KsColors.ink3,
                                              fontSize: 11)),
                                    if (tookOffline)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: KsColors.warningTint,
                                          borderRadius:
                                              BorderRadius.circular(KsRadius.pill),
                                        ),
                                        child: const Text('Took bike offline',
                                            style: TextStyle(
                                                color: KsColors.warning,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w700)),
                                      ),
                                  ]),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (incidentId.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 24, top: 8),
                            child: _FollowupsBlock(incidentId: incidentId),
                          ),
                      ]),
                );
              }).toList(),
            ),
    );
  }
}

// ---------------- Incident follow-ups ----------------

final _followupsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, incidentId) async {
  return ref.read(apiClientProvider).listIncidentFollowups(incidentId);
});

class _FollowupsBlock extends ConsumerWidget {
  final String incidentId;
  const _FollowupsBlock({required this.incidentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_followupsProvider(incidentId));
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (rows) {
        if (rows.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('FOLLOW-UPS',
                style: GoogleFonts.plusJakartaSans(
                    color: KsColors.ink3,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5)),
            const SizedBox(height: 4),
            for (final r in rows)
              _FollowupRow(incidentId: incidentId, row: r),
          ],
        );
      },
    );
  }
}

class _FollowupRow extends ConsumerStatefulWidget {
  final String incidentId;
  final Map<String, dynamic> row;
  const _FollowupRow({required this.incidentId, required this.row});
  @override
  ConsumerState<_FollowupRow> createState() => _FollowupRowState();
}

class _FollowupRowState extends ConsumerState<_FollowupRow> {
  bool _busy = false;

  Future<void> _toggle() async {
    final id = (widget.row['id'] ?? '') as String;
    final done = (widget.row['done'] ?? false) as bool;
    setState(() => _busy = true);
    try {
      if (done) {
        await ref.read(apiClientProvider).reopenFollowup(id);
      } else {
        await ref.read(apiClientProvider).completeFollowup(followupId: id);
      }
      ref.invalidate(_followupsProvider(widget.incidentId));
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
    final done = (r['done'] ?? false) as bool;
    final kind = (r['kind'] ?? '') as String;
    final description = (r['description'] ?? '') as String;
    final dueOn = (r['dueOn'] ?? '') as String;
    final today = DateTime.now();
    final dueParsed = DateTime.tryParse(dueOn);
    final overdue = !done &&
        dueParsed != null &&
        dueParsed.isBefore(DateTime(today.year, today.month, today.day));
    final kindLabel = switch (kind) {
      'mechanical_check' => 'Mechanical check',
      'student_welfare' => 'Welfare call',
      'insurance_notify' => 'Insurance notify',
      _ => 'Follow-up',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : InkWell(
                onTap: _toggle,
                child: Icon(
                  done
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
                  color: done ? KsColors.success : KsColors.ink3,
                  size: 18,
                ),
              ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(kindLabel,
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        decoration: done ? TextDecoration.lineThrough : null,
                        color: done ? KsColors.ink3 : KsColors.ink)),
                Text(description,
                    style: TextStyle(
                        color: done ? KsColors.ink4 : KsColors.ink3,
                        fontSize: 11.5)),
              ]),
        ),
        if (overdue)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: KsColors.dangerTint,
              borderRadius: BorderRadius.circular(KsRadius.pill),
            ),
            child: Text('Overdue · $dueOn',
                style: GoogleFonts.plusJakartaSans(
                    color: KsColors.danger,
                    fontSize: 10,
                    fontWeight: FontWeight.w800)),
          )
        else if (!done && dueOn.isNotEmpty)
          Text('Due $dueOn',
              style: const TextStyle(
                  color: KsColors.ink3, fontSize: 10.5)),
      ]),
    );
  }
}

// ---------------- Reusable card ----------------

class _Card extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;
  const _Card({required this.title, required this.icon, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
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
          Row(children: [
            Icon(icon, color: KsColors.primary, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 15)),
            ),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

// ---------------- Money formatter ----------------

String _money(int pence, {bool withSign = false}) {
  final neg = pence < 0;
  final p = pence.abs();
  final pounds = p ~/ 100;
  final cents = p % 100;
  final core = '£${NumberFormat('#,##0').format(pounds)}.${cents.toString().padLeft(2, '0')}';
  if (!withSign) return core;
  return (neg ? '-' : '') + core;
}

// ---------------- Add charge sheet ----------------

Future<void> _showAddChargeSheet(BuildContext context, WidgetRef ref, String studentId) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _AddChargeSheet(studentId: studentId),
  );
}

class _AddChargeSheet extends ConsumerStatefulWidget {
  final String studentId;
  const _AddChargeSheet({required this.studentId});
  @override
  ConsumerState<_AddChargeSheet> createState() => _AddChargeSheetState();
}

class _AddChargeSheetState extends ConsumerState<_AddChargeSheet> {
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  int? _parsePence(String s) {
    final v = double.tryParse(s.trim());
    if (v == null || v <= 0) return null;
    return (v * 100).round();
  }

  Future<void> _submit() async {
    final pence = _parsePence(_amountCtrl.text);
    if (pence == null) {
      setState(() => _error = 'Enter a positive amount.');
      return;
    }
    if (_descCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Description required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).addStudentCharge(
            studentId: widget.studentId,
            amountPence: pence,
            description: _descCtrl.text.trim(),
          );
      ref.invalidate(_studentDetailProvider(widget.studentId));
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
              Text('Add charge',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 19, fontWeight: FontWeight.w800, color: KsColors.ink)),
              const SizedBox(height: 16),
              TextField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: '£ ',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'e.g. CBT 125 day',
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
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                    : const Text('Add charge'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- Add note sheet ----------------

Future<void> _showAddNoteSheet(BuildContext context, WidgetRef ref, String studentId) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _AddNoteSheet(studentId: studentId),
  );
}

class _AddNoteSheet extends ConsumerStatefulWidget {
  final String studentId;
  const _AddNoteSheet({required this.studentId});
  @override
  ConsumerState<_AddNoteSheet> createState() => _AddNoteSheetState();
}

class _AddNoteSheetState extends ConsumerState<_AddNoteSheet> {
  final _bodyCtrl = TextEditingController();
  String _kind = 'safety_flag';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_bodyCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Note required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).addStudentNote(
            studentId: widget.studentId,
            kind: _kind,
            body: _bodyCtrl.text.trim(),
          );
      ref.invalidate(_studentDetailProvider(widget.studentId));
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
              Text('Add note',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 19, fontWeight: FontWeight.w800, color: KsColors.ink)),
              const SizedBox(height: 4),
              const Text(
                'Staff-only. Be factual — students can request access.',
                style: TextStyle(color: KsColors.ink3, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: _KindOption(
                    label: 'Safety flag',
                    icon: Icons.warning_amber_rounded,
                    selected: _kind == 'safety_flag',
                    onTap: () => setState(() => _kind = 'safety_flag'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _KindOption(
                    label: 'Progress note',
                    icon: Icons.notes,
                    selected: _kind == 'progress_note',
                    onTap: () => setState(() => _kind = 'progress_note'),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              TextField(
                controller: _bodyCtrl,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: _kind == 'safety_flag'
                      ? 'e.g. Requires low-seat bike'
                      : 'e.g. Strong slow control, struggles on roundabouts',
                  border: const OutlineInputBorder(),
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
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KindOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _KindOption({
    required this.label, required this.icon, required this.selected, required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected ? KsColors.primaryTint : KsColors.surface2,
          borderRadius: BorderRadius.circular(KsRadius.md),
          border: Border.all(
            color: selected ? KsColors.primary.withValues(alpha: 0.5) : KsColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: selected ? KsColors.primaryDeep : KsColors.ink3),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                  color: selected ? KsColors.primaryDeep : KsColors.ink2,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                )),
          ],
        ),
      ),
    );
  }
}

/// Bottom-of-page card that hosts irreversible operations on a
/// student. Today: the GDPR Article 17 right-to-erasure flow that
/// anonymises the user. If the student is already anonymised, the
/// card shows a read-only confirmation pill instead of the button.
class _DangerZoneCard extends ConsumerWidget {
  final String studentId;
  final String anonymisedAt;
  final VoidCallback onAnonymised;
  const _DangerZoneCard({
    required this.studentId,
    required this.anonymisedAt,
    required this.onAnonymised,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scrubbed = anonymisedAt.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: KsColors.dangerTint,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.danger.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.shield_outlined, color: KsColors.danger, size: 18),
            const SizedBox(width: 8),
            Text(
              'Danger zone · GDPR',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: KsColors.danger,
              ),
            ),
          ]),
          const SizedBox(height: 10),
          if (scrubbed)
            Text(
              'This account was anonymised on ${_formatDate(anonymisedAt)}. '
              'PII has been scrubbed; bookings, charges, and audit history '
              'have been preserved per financial-retention obligations.',
              style: const TextStyle(color: KsColors.ink2, fontSize: 13, height: 1.4),
            )
          else ...[
            const Text(
              'Right to erasure (Article 17). Replaces name / email / phone '
              'with placeholders, disables Firebase sign-in, and stamps an '
              'erasure timestamp. Bookings, charges, payments, and audit log '
              'are preserved so the school\'s records stay intact. '
              'This action is irreversible.',
              style: TextStyle(color: KsColors.ink2, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => _confirmAndAnonymise(context, ref),
                icon: const Icon(Icons.delete_forever, size: 18),
                label: const Text('Anonymise this account'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: KsColors.danger,
                  side: const BorderSide(color: KsColors.danger),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmAndAnonymise(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Anonymise this account?'),
        content: const Text(
          'This permanently scrubs identifying data and disables sign-in. '
          'It cannot be undone. The student\'s bookings and ledger will '
          'remain on the school\'s books with placeholder names.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: KsColors.danger),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Anonymise'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).anonymiseUser(userId: studentId);
      onAnonymised();
      messenger.showSnackBar(const SnackBar(content: Text('Account anonymised.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Anonymise failed: $e')));
    }
  }

  String _formatDate(String iso) {
    final at = DateTime.tryParse(iso);
    if (at == null) return iso;
    return DateFormat('d MMM yyyy · HH:mm').format(at.toLocal());
  }
}
