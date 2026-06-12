// Bottom sheet: staff log an incident on a bike / student / booking.
//
// Wired in from the instructor session-detail roster (each booking row
// gets an overflow menu with "Report incident"). The same sheet covers
// the safety-critical "I had a crash, taking the bike off the road"
// flow by toggling "Take bike offline" on — the backend rolls the
// incident insert + bike-offline + disruption fan-out into one tx so
// the instructor can't end up half-done.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';

class ReportIncidentSheet extends ConsumerStatefulWidget {
  final String? bikeId;
  final String? bikeLabel; // displayable — nickname + reg, or just nickname
  final String? studentId;
  final String? studentName;
  final String? bookingId;
  final VoidCallback onLogged;

  const ReportIncidentSheet({
    super.key,
    this.bikeId,
    this.bikeLabel,
    this.studentId,
    this.studentName,
    this.bookingId,
    required this.onLogged,
  });

  static Future<bool?> show(
    BuildContext context, {
    String? bikeId,
    String? bikeLabel,
    String? studentId,
    String? studentName,
    String? bookingId,
    required VoidCallback onLogged,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KsColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
      ),
      builder: (_) => ReportIncidentSheet(
        bikeId: bikeId,
        bikeLabel: bikeLabel,
        studentId: studentId,
        studentName: studentName,
        bookingId: bookingId,
        onLogged: onLogged,
      ),
    );
  }

  @override
  ConsumerState<ReportIncidentSheet> createState() => _ReportIncidentSheetState();
}

class _ReportIncidentSheetState extends ConsumerState<ReportIncidentSheet> {
  late final TextEditingController _descCtrl;
  bool _takeOffline = false;
  String _reason = 'damaged';
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
    _descCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final desc = _descCtrl.text.trim();
    if (desc.isEmpty) {
      setState(() => _error = 'Describe what happened.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).logIncident(
            bikeId: widget.bikeId,
            studentId: widget.studentId,
            bookingId: widget.bookingId,
            description: desc,
            takeBikeOffline: _takeOffline,
            offlineReason: _takeOffline ? _reason : null,
          );
      if (!mounted) return;
      widget.onLogged();
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not log. Try again.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets;
    final canOffline = (widget.bikeId ?? '').isNotEmpty;
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
                Text('Report incident',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink,
                        letterSpacing: -0.4)),
                if ((widget.studentName ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(widget.studentName!,
                      style: const TextStyle(
                          color: KsColors.ink2, fontWeight: FontWeight.w600)),
                ],
                if ((widget.bikeLabel ?? '').isNotEmpty) ...[
                  const SizedBox(height: 12),
                  // Prominent bike card — without it the instructor has
                  // to flip back to the roster mid-form to remember
                  // which bike they're filing against.
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
                          color: KsColors.primaryTint,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.two_wheeler,
                            color: KsColors.primaryDeep, size: 20),
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
                            Text(widget.bikeLabel!,
                                style: GoogleFonts.plusJakartaSans(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: KsColors.ink)),
                          ],
                        ),
                      ),
                    ]),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _descCtrl,
                  autofocus: true,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'What happened?',
                    hintText:
                        'Drop at low speed during slalom — no injuries, bike scuffed.',
                    alignLabelWithHint: true,
                  ),
                ),
                if (canOffline) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: _takeOffline
                          ? KsColors.warningTint
                          : KsColors.surface2,
                      borderRadius: BorderRadius.circular(KsRadius.md),
                      border: Border.all(
                        color: _takeOffline
                            ? KsColors.warning.withValues(alpha: 0.4)
                            : KsColors.border,
                      ),
                    ),
                    child: SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: _takeOffline,
                      onChanged: (v) => setState(() => _takeOffline = v),
                      title: Text('Take bike offline',
                          style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w800,
                              color: KsColors.ink,
                              fontSize: 14)),
                      subtitle: Text(
                        _takeOffline
                            ? 'Cancels / flags affected bookings.'
                            : 'Leave the bike in service.',
                        style: const TextStyle(
                            color: KsColors.ink3, fontSize: 12),
                      ),
                    ),
                  ),
                  if (_takeOffline) ...[
                    const SizedBox(height: 12),
                    Text('Reason',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: KsColors.ink)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _reasons
                          .map((r) => _reasonChip(r.$1, r.$2))
                          .toList(),
                    ),
                  ],
                ],
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
                      : const Icon(Icons.warning_amber_rounded, size: 18),
                  label: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5))
                      : Text(_takeOffline
                          ? 'Log incident & take bike offline'
                          : 'Log incident'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _takeOffline ? KsColors.warning : KsColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Recorded against you. Admin reviews follow-ups in the Incidents board.',
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
