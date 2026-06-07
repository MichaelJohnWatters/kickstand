// Admin Instructor pay — "what we owe Dave" view.
//
// Per plan §3 — this is owed-tracking, NOT payroll.
// Total outstanding header + per-instructor row with earned/paid/outstanding
// and quick actions: Record earning, Record payment, Set pay model.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';

class AdminInstructorPayScreen extends ConsumerWidget {
  const AdminInstructorPayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(instructorPayOutstandingProvider);
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(instructorPayOutstandingProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Instructor pay',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 28, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.6)),
          const SizedBox(height: 6),
          const Text(
            'Owed-tracking, not payroll. Record earnings as they accrue, record payments as you settle them.',
            style: TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 20),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => Text('Couldn’t load.\n$e'),
            data: (rows) {
              final totalOutstanding = rows.fold<int>(0, (s, r) => s + r.outstandingPence);
              return Column(children: [
                _TotalHeader(totalOutstanding: totalOutstanding, instructorCount: rows.length),
                const SizedBox(height: 18),
                if (rows.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(40),
                    decoration: BoxDecoration(
                      color: KsColors.surface,
                      borderRadius: BorderRadius.circular(KsRadius.lg),
                      border: Border.all(color: KsColors.border),
                    ),
                    child: Column(children: [
                      const Icon(Icons.group_outlined, size: 48, color: KsColors.ink4),
                      const SizedBox(height: 12),
                      Text('No instructors yet',
                          style: GoogleFonts.plusJakartaSans(
                              fontSize: 16, fontWeight: FontWeight.w700, color: KsColors.ink)),
                    ]),
                  )
                else
                  ...rows.map((r) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _InstructorRow(row: r),
                      )),
              ]);
            },
          ),
        ],
      ),
    );
  }
}

class _TotalHeader extends StatelessWidget {
  final int totalOutstanding;
  final int instructorCount;
  const _TotalHeader({required this.totalOutstanding, required this.instructorCount});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [KsColors.primary, KsColors.primaryDeep],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(KsRadius.lg),
        boxShadow: KsShadows.shPrimary,
      ),
      child: Row(children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(KsRadius.sm),
          ),
          child: const Icon(Icons.account_balance_wallet_outlined, color: Colors.white, size: 26),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total outstanding',
                  style: GoogleFonts.plusJakartaSans(
                      color: Colors.white.withValues(alpha: 0.85), fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(_money(totalOutstanding),
                  style: GoogleFonts.plusJakartaSans(
                      color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: -1)),
              const SizedBox(height: 4),
              Text(
                instructorCount == 1
                    ? 'Across 1 instructor'
                    : 'Across $instructorCount instructors',
                style: GoogleFonts.plusJakartaSans(
                    color: Colors.white.withValues(alpha: 0.9), fontSize: 12),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _InstructorRow extends ConsumerWidget {
  final InstructorPayRow row;
  const _InstructorRow({required this.row});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: KsColors.primaryTint,
                borderRadius: BorderRadius.circular(KsRadius.pill),
              ),
              child: const Icon(Icons.person, color: KsColors.primaryDeep, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(row.instructorName,
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 16)),
            ),
            _OutstandingBadge(amount: row.outstandingPence),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            _stat('Earned', row.totalEarnedPence, KsColors.ink),
            const SizedBox(width: 16),
            _stat('Paid', row.totalPaidPence, KsColors.success),
            const SizedBox(width: 16),
            _stat('Outstanding', row.outstandingPence,
                row.outstandingPence > 0 ? KsColors.danger : KsColors.ink3),
          ]),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: () => _showRecordEarningSheet(context, ref, row),
              icon: const Icon(Icons.trending_up, size: 16),
              label: const Text('Record earning'),
            ),
            ElevatedButton.icon(
              onPressed: () => _showRecordPaymentSheet(context, ref, row),
              icon: const Icon(Icons.payments_outlined, size: 16),
              label: const Text('Record payment'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: row.outstandingPence > 0 ? KsColors.primary : KsColors.ink4),
            ),
            OutlinedButton.icon(
              onPressed: () => _showSetPayModelSheet(context, ref, row),
              icon: const Icon(Icons.tune, size: 16),
              label: const Text('Pay model'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _stat(String label, int amount, Color colour) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(color: KsColors.ink3, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            const SizedBox(height: 4),
            Text(_money(amount),
                style: GoogleFonts.plusJakartaSans(
                    color: colour, fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: -0.3)),
          ],
        ),
      );
}

class _OutstandingBadge extends StatelessWidget {
  final int amount;
  const _OutstandingBadge({required this.amount});
  @override
  Widget build(BuildContext context) {
    if (amount <= 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: KsColors.successTint,
          borderRadius: BorderRadius.circular(KsRadius.pill),
        ),
        child: const Text('Settled',
            style: TextStyle(color: KsColors.success, fontWeight: FontWeight.w700, fontSize: 11)),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: KsColors.dangerTint,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text('Owes ${_money(amount)}',
          style: const TextStyle(color: KsColors.danger, fontWeight: FontWeight.w700, fontSize: 11)),
    );
  }
}

// ---------------- Record earning sheet ----------------

Future<void> _showRecordEarningSheet(BuildContext context, WidgetRef ref, InstructorPayRow row) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _RecordEarningSheet(row: row),
  );
}

class _RecordEarningSheet extends ConsumerStatefulWidget {
  final InstructorPayRow row;
  const _RecordEarningSheet({required this.row});
  @override
  ConsumerState<_RecordEarningSheet> createState() => _RecordEarningSheetState();
}

class _RecordEarningSheetState extends ConsumerState<_RecordEarningSheet> {
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  String _basis = 'per_day';
  bool _saving = false;
  String? _error;

  static const _bases = [
    ('per_day', 'Per day'),
    ('per_session', 'Per session'),
    ('per_hour', 'Per hour'),
    ('per_student', 'Per student'),
    ('percentage', '% of session'),
  ];

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  int? _parsePence(String s) {
    final v = double.tryParse(s.trim());
    if (v == null || v <= 0) return null;
    return (v * 100).round();
  }

  Future<void> _submit() async {
    final pence = _parsePence(_amount.text);
    if (pence == null) {
      setState(() => _error = 'Enter a positive amount.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).recordInstructorEarning(
            instructorId: widget.row.instructorId,
            amountPence: pence,
            basis: _basis,
            notes: _notes.text.trim(),
          );
      ref.invalidate(instructorPayOutstandingProvider);
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
              Text('Record earning · ${widget.row.instructorName}',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 18, fontWeight: FontWeight.w800, color: KsColors.ink)),
              const SizedBox(height: 16),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: const InputDecoration(labelText: 'Amount', prefixText: '£ '),
                autofocus: true,
              ),
              const SizedBox(height: 14),
              Text('Basis',
                  style: GoogleFonts.plusJakartaSans(
                      color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: _bases.map((b) {
                final on = _basis == b.$1;
                return _picker(label: b.$2, selected: on, onTap: () => setState(() => _basis = b.$1));
              }).toList()),
              const SizedBox(height: 14),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
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
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                    : const Text('Record earning'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- Record payment sheet ----------------

Future<void> _showRecordPaymentSheet(BuildContext context, WidgetRef ref, InstructorPayRow row) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _RecordInstrPaymentSheet(row: row),
  );
}

class _RecordInstrPaymentSheet extends ConsumerStatefulWidget {
  final InstructorPayRow row;
  const _RecordInstrPaymentSheet({required this.row});
  @override
  ConsumerState<_RecordInstrPaymentSheet> createState() => _RecordInstrPaymentSheetState();
}

class _RecordInstrPaymentSheetState extends ConsumerState<_RecordInstrPaymentSheet> {
  late TextEditingController _amount;
  final _notes = TextEditingController();
  String _method = 'bank_transfer';
  bool _saving = false;
  String? _error;

  static const _methods = [
    ('cash', 'Cash'),
    ('bank_transfer', 'Bank transfer'),
    ('card_in_person', 'Card'),
    ('other', 'Other'),
  ];

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(
      text: (widget.row.outstandingPence / 100).toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  int? _parsePence(String s) {
    final v = double.tryParse(s.trim());
    if (v == null || v <= 0) return null;
    return (v * 100).round();
  }

  Future<void> _submit() async {
    final pence = _parsePence(_amount.text);
    if (pence == null) {
      setState(() => _error = 'Enter a positive amount.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).recordInstructorPayment(
            instructorId: widget.row.instructorId,
            amountPence: pence,
            method: _method,
            notes: _notes.text.trim(),
          );
      ref.invalidate(instructorPayOutstandingProvider);
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
              Text('Pay ${widget.row.instructorName}',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 18, fontWeight: FontWeight.w800, color: KsColors.ink)),
              const SizedBox(height: 4),
              Text('Outstanding ${_money(widget.row.outstandingPence)}',
                  style: const TextStyle(color: KsColors.ink2)),
              const SizedBox(height: 16),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: const InputDecoration(labelText: 'Amount', prefixText: '£ '),
                autofocus: true,
              ),
              const SizedBox(height: 14),
              Text('Method',
                  style: GoogleFonts.plusJakartaSans(
                      color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: _methods.map((m) {
                final on = _method == m.$1;
                return _picker(label: m.$2, selected: on, onTap: () => setState(() => _method = m.$1));
              }).toList()),
              const SizedBox(height: 14),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
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
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                    : const Text('Record payment'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- Set pay model sheet ----------------

Future<void> _showSetPayModelSheet(BuildContext context, WidgetRef ref, InstructorPayRow row) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _SetPayModelSheet(row: row),
  );
}

class _SetPayModelSheet extends ConsumerStatefulWidget {
  final InstructorPayRow row;
  const _SetPayModelSheet({required this.row});
  @override
  ConsumerState<_SetPayModelSheet> createState() => _SetPayModelSheetState();
}

class _SetPayModelSheetState extends ConsumerState<_SetPayModelSheet> {
  final _rate = TextEditingController();
  String _basis = 'per_day';
  bool _saving = false;
  String? _error;
  bool _loading = true;

  static const _bases = [
    ('per_day', 'Per day', '£ amount'),
    ('per_session', 'Per session', '£ amount'),
    ('per_hour', 'Per hour', '£ amount'),
    ('per_student', 'Per student', '£ amount'),
    ('percentage', 'Percentage', '%'),
    ('salary', 'Salaried (not tracked)', ''),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await ref.read(apiClientProvider).getInstructorPayModel(widget.row.instructorId);
      if (m != null) {
        _basis = m.payBasis;
        if (m.payBasis == 'percentage') {
          _rate.text = (m.rateValue / 100).toStringAsFixed(2);
        } else {
          _rate.text = (m.rateValue / 100).toStringAsFixed(2);
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    int? rateValue;
    if (_basis == 'salary') {
      rateValue = 0;
    } else if (_basis == 'percentage') {
      final pct = double.tryParse(_rate.text.trim());
      if (pct == null || pct < 0 || pct > 100) {
        setState(() => _error = 'Enter a percentage between 0 and 100.');
        return;
      }
      // basis-points (10000 = 100%)
      rateValue = (pct * 100).round();
    } else {
      final v = double.tryParse(_rate.text.trim());
      if (v == null || v < 0) {
        setState(() => _error = 'Enter a non-negative amount.');
        return;
      }
      rateValue = (v * 100).round();
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).setInstructorPayModel(
            instructorId: widget.row.instructorId,
            payBasis: _basis,
            rateValue: rateValue,
          );
      ref.invalidate(instructorPayOutstandingProvider);
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
    final basisSpec = _bases.firstWhere((b) => b.$1 == _basis, orElse: () => _bases.first);
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
              Text('Pay model · ${widget.row.instructorName}',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 18, fontWeight: FontWeight.w800, color: KsColors.ink)),
              const SizedBox(height: 16),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
                )
              else ...[
                Wrap(spacing: 6, runSpacing: 6, children: _bases.map((b) {
                  final on = _basis == b.$1;
                  return _picker(label: b.$2, selected: on, onTap: () => setState(() => _basis = b.$1));
                }).toList()),
                if (_basis != 'salary') ...[
                  const SizedBox(height: 14),
                  TextField(
                    controller: _rate,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: InputDecoration(
                      labelText: basisSpec.$2,
                      prefixText: _basis == 'percentage' ? '' : '£ ',
                      suffixText: _basis == 'percentage' ? '%' : '',
                    ),
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
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                      : const Text('Save pay model'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- helpers ----------------

String _money(int pence) {
  final neg = pence < 0;
  final p = pence.abs();
  final pounds = p ~/ 100;
  final cents = p % 100;
  return '${neg ? '-' : ''}£${NumberFormat('#,##0').format(pounds)}.${cents.toString().padLeft(2, '0')}';
}

Widget _picker({required String label, required bool selected, required VoidCallback onTap}) {
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
            fontWeight: FontWeight.w700, fontSize: 12,
          )),
    ),
  );
}
