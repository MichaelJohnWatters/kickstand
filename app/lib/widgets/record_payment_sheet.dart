// Bottom sheet: instructor records a student payment in the field.
//
// Per plan: record-only (no void / no charge editing). The server stamps
// recorded_by from the bearer token, so the field "stamped by Dave"
// appears automatically in the ledger.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';

class RecordPaymentSheet extends ConsumerStatefulWidget {
  final String studentId;
  final String studentName;
  final int outstandingPence;
  final VoidCallback onRecorded;

  const RecordPaymentSheet({
    super.key,
    required this.studentId,
    required this.studentName,
    required this.outstandingPence,
    required this.onRecorded,
  });

  /// Helper: show the sheet on top of [context]. Returns true if a payment
  /// was recorded (the caller can refresh).
  static Future<bool?> show(
    BuildContext context, {
    required String studentId,
    required String studentName,
    required int outstandingPence,
    required VoidCallback onRecorded,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KsColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
      ),
      builder: (_) => RecordPaymentSheet(
        studentId: studentId,
        studentName: studentName,
        outstandingPence: outstandingPence,
        onRecorded: onRecorded,
      ),
    );
  }

  @override
  ConsumerState<RecordPaymentSheet> createState() => _RecordPaymentSheetState();
}

class _RecordPaymentSheetState extends ConsumerState<RecordPaymentSheet> {
  late TextEditingController _amountCtrl;
  late TextEditingController _notesCtrl;
  String _method = 'cash';
  bool _saving = false;
  String? _error;

  static const _methods = [
    _MethodOption('cash', 'Cash', Icons.payments),
    _MethodOption('bank_transfer', 'Bank transfer', Icons.account_balance),
    _MethodOption('card_in_person', 'Card', Icons.credit_card),
    _MethodOption('other', 'Other', Icons.more_horiz),
  ];

  @override
  void initState() {
    super.initState();
    // Default to the full outstanding amount, rendered as £X.YZ. The user
    // can edit it for partial payments.
    _amountCtrl = TextEditingController(
      text: (widget.outstandingPence / 100).toStringAsFixed(2),
    );
    _notesCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  /// Convert "12.34" → 1234 pence. Tolerates "12" (= 1200 pence) and "12.3".
  /// Returns null if the input isn't a positive number.
  int? _parsePence(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final v = double.tryParse(s);
    if (v == null || v <= 0) return null;
    return (v * 100).round();
  }

  Future<void> _submit() async {
    final pence = _parsePence(_amountCtrl.text);
    if (pence == null) {
      setState(() => _error = 'Enter a positive amount in pounds (e.g. 130 or 65.50).');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).recordStudentPayment(
            studentId: widget.studentId,
            amountPence: pence,
            method: _method,
            notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
          );
      if (!mounted) return;
      // Fire the caller-supplied invalidator FIRST (so the underlying
      // route's provider transitions to loading before we pop), then
      // close. Pop returns true so callers using the boolean future can
      // double-up the refresh if their callback didn't catch.
      widget.onRecorded();
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() {
        _error = e.code == 'forbidden'
            ? 'Your school doesn’t allow instructors to record payments.'
            : e.message;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not record. Try again.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Re-position above the on-screen keyboard.
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
              Text('Record payment',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 19, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.4)),
              const SizedBox(height: 4),
              Text(
                '${widget.studentName} · outstanding £${(widget.outstandingPence / 100).toStringAsFixed(2)}',
                style: const TextStyle(color: KsColors.ink2),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: '£ ',
                  prefixStyle: TextStyle(color: KsColors.ink, fontWeight: FontWeight.w700),
                ),
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w700, color: KsColors.ink, fontSize: 17),
                autofocus: true,
              ),
              const SizedBox(height: 14),
              Text('Method',
                  style: GoogleFonts.plusJakartaSans(
                      color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: _methods.map((m) => _MethodChip(
                      label: m.label,
                      icon: m.icon,
                      selected: _method == m.value,
                      onTap: () => setState(() => _method = m.value),
                    )).toList(),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _notesCtrl,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'e.g. balance for CBT, paid at site',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: KsColors.dangerTint,
                    borderRadius: BorderRadius.circular(KsRadius.md),
                    border: Border.all(color: KsColors.danger.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: KsColors.danger, size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Text(_error!, style: const TextStyle(color: KsColors.danger))),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Text('Record payment'),
              ),
              const SizedBox(height: 8),
              Text(
                'Recorded by you. Voids and charge edits stay with the school admin.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: KsColors.ink3, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MethodOption {
  final String value;
  final String label;
  final IconData icon;
  const _MethodOption(this.value, this.label, this.icon);
}

class _MethodChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _MethodChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? KsColors.primaryTint : KsColors.surface2,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(
            color: selected ? KsColors.primary.withValues(alpha: 0.5) : KsColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? KsColors.primaryDeep : KsColors.ink3),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: selected ? KsColors.primaryDeep : KsColors.ink2,
                  fontSize: 13,
                )),
          ],
        ),
      ),
    );
  }
}
