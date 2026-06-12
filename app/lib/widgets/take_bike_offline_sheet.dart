// Bottom sheet: take a bike out of service without a per-student
// incident attached. Use case is the start-of-day check — instructor
// spots an issue on a bike before any rider gets on it, flips it
// offline, and the affected-bookings fan-out picks up from there.
//
// Sister flow to ReportIncidentSheet, which is the per-rider "I had a
// crash, taking the bike off the road" path. Keeping these separate so
// neither has to compromise: incident wants a description, this one
// shouldn't.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';

class TakeBikeOfflineSheet extends ConsumerStatefulWidget {
  final String bikeId;
  final String bikeLabel;
  final VoidCallback onDone;

  const TakeBikeOfflineSheet({
    super.key,
    required this.bikeId,
    required this.bikeLabel,
    required this.onDone,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String bikeId,
    required String bikeLabel,
    required VoidCallback onDone,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KsColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
      ),
      builder: (_) => TakeBikeOfflineSheet(
        bikeId: bikeId,
        bikeLabel: bikeLabel,
        onDone: onDone,
      ),
    );
  }

  @override
  ConsumerState<TakeBikeOfflineSheet> createState() =>
      _TakeBikeOfflineSheetState();
}

class _TakeBikeOfflineSheetState extends ConsumerState<TakeBikeOfflineSheet> {
  String _reason = 'damaged';
  late final TextEditingController _notesCtrl;
  bool _saving = false;
  String? _error;

  static const _reasons = <(String, String)>[
    ('damaged', 'Damaged'),
    ('broken', 'Broken'),
    ('mechanic', 'At mechanic'),
    ('off_road', 'Off-road'),
    ('other', 'Other'),
  ];

  @override
  void initState() {
    super.initState();
    _notesCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).takeBikeOffline(
            bikeId: widget.bikeId,
            reason: _reason,
            notes:
                _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
          );
      if (!mounted) return;
      widget.onDone();
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not take offline. Try again.';
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
              mainAxisSize: MainAxisSize.min,
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
                Text('Take bike offline',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink,
                        letterSpacing: -0.4)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: KsColors.surface2,
                    borderRadius: BorderRadius.circular(KsRadius.md),
                    border: Border.all(color: KsColors.border),
                  ),
                  child: Row(children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: KsColors.warningTint,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.two_wheeler,
                          color: KsColors.warning, size: 20),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('BIKE',
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: KsColors.ink4,
                                  letterSpacing: 0.5)),
                          const SizedBox(height: 1),
                          Text(widget.bikeLabel,
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: KsColors.ink)),
                        ],
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                Text('Reason',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children:
                      _reasons.map((r) => _reasonChip(r.$1, r.$2)).toList(),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _notesCtrl,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    hintText: 'e.g. brake lever bent, clutch slipping',
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
                    child: Row(children: [
                      const Icon(Icons.error_outline,
                          color: KsColors.danger, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_error!,
                            style: const TextStyle(color: KsColors.danger)),
                      ),
                    ]),
                  ),
                ],
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _saving ? null : _submit,
                  icon: _saving
                      ? const SizedBox.shrink()
                      : const Icon(Icons.do_not_disturb_on_outlined, size: 18),
                  label: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5))
                      : const Text('Take offline'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: KsColors.warning,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Any bookings on this bike flip to "needs reassignment".',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: KsColors.ink4, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _reasonChip(String value, String label) {
    final selected = value == _reason;
    return InkWell(
      onTap: () => setState(() => _reason = value),
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? KsColors.warningTint : KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(
              color: selected
                  ? KsColors.warning.withValues(alpha: 0.5)
                  : KsColors.border,
              width: selected ? 1.5 : 1),
        ),
        child: Text(label,
            style: GoogleFonts.plusJakartaSans(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: selected ? KsColors.warning : KsColors.ink3)),
      ),
    );
  }
}
