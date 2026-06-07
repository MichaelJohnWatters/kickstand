// Instructor session detail — student list with safety flags, outstanding
// balance, bike assignment. Attendance + competency capture come next.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../state/providers.dart';
import '../state/school.dart';
import '../theme/tokens.dart';
import '../widgets/notification_bell.dart';
import '../widgets/record_payment_sheet.dart';

final sessionDetailProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  final api = ref.read(apiClientProvider);
  return api.sessionDetail(id);
});

class InstructorSessionDetailScreen extends ConsumerWidget {
  final String sessionId;
  const InstructorSessionDetailScreen({required this.sessionId, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sessionDetailProvider(sessionId));
    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: Text('Session',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 22)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: KsColors.ink),
          onPressed: () => context.pop(),
        ),
        actions: const [NotificationBell()],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator(color: KsColors.primary)),
        error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Couldn’t load.\n$e'))),
        data: (d) {
          final bookings = ((d['bookings'] as List?) ?? const []).cast<Map<String, dynamic>>();
          final startsAt = DateTime.tryParse(d['startsAt'] ?? '')?.toLocal();
          final endsAt = DateTime.tryParse(d['endsAt'] ?? '')?.toLocal();
          final df = DateFormat('EEE d MMM');
          final tf = DateFormat('HH:mm');
          final nonTeaching = d['nonTeaching'] ?? false;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
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
                      Expanded(
                        child: Text(d['courseName'] ?? '',
                            style: GoogleFonts.plusJakartaSans(
                                fontSize: 19, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.4)),
                      ),
                      if (nonTeaching)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: KsColors.warningTint,
                            borderRadius: BorderRadius.circular(KsRadius.pill),
                          ),
                          child: const Text('Test day',
                              style: TextStyle(color: KsColors.warning, fontWeight: FontWeight.w700, fontSize: 12)),
                        ),
                    ]),
                    const SizedBox(height: 10),
                    if (startsAt != null && endsAt != null)
                      _row(Icons.schedule, '${df.format(startsAt)} · ${tf.format(startsAt)}–${tf.format(endsAt)}'),
                    _row(Icons.place_outlined, d['locationName'] ?? ''),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(children: [
                Text('Students', style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, fontSize: 17, color: KsColors.ink)),
                const Spacer(),
                Text('${bookings.length} booked',
                    style: const TextStyle(color: KsColors.ink3, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 10),
              if (bookings.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: KsColors.surface2,
                    borderRadius: BorderRadius.circular(KsRadius.md),
                    border: Border.all(color: KsColors.border),
                  ),
                  child: const Text('No students booked yet.',
                      style: TextStyle(color: KsColors.ink2)),
                )
              else
                ...bookings.map((b) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _StudentCard(b),
                )),
            ],
          );
        },
      ),
    );
  }

  Widget _row(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Icon(icon, size: 16, color: KsColors.ink3),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(color: KsColors.ink2, fontSize: 14))),
        ]),
      );
}

class _StudentCard extends ConsumerWidget {
  final Map<String, dynamic> b;
  const _StudentCard(this.b);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flags = ((b['safetyFlags'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final phone = (b['studentPhone'] ?? '').toString();
    final bike = (b['bikeNickname'] ?? '').toString();
    final outstanding = (b['outstandingPence'] ?? 0) as int;
    final status = (b['status'] ?? '').toString();
    final bookingId = (b['bookingId'] ?? '').toString();
    final sessionId = (b['sessionId'] ?? '').toString();
    final studentId = (b['studentId'] ?? '').toString();
    final studentName = (b['studentName'] ?? '').toString();
    final settings = ref.watch(schoolSettingsProvider).valueOrNull;
    final canRecordPayment = (settings?.instructorsCanRecordPayments ?? false) && outstanding > 0;

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
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: KsColors.primaryTint,
                borderRadius: BorderRadius.circular(KsRadius.pill),
              ),
              child: const Icon(Icons.person, color: KsColors.primaryDeep, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b['studentName'] ?? '',
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w700, color: KsColors.ink, fontSize: 15)),
                  if (bike.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(bike, style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
                  ],
                ],
              ),
            ),
            _StatusChip(status),
          ]),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 10),
            _row(Icons.phone, phone),
          ],
          if (flags.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...flags.map((f) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: KsColors.warningTint,
                  borderRadius: BorderRadius.circular(KsRadius.md),
                  border: Border.all(color: KsColors.warning.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: KsColors.warning, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(f['body'] ?? '',
                          style: const TextStyle(color: KsColors.warning, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            )),
          ],
          if (outstanding > 0) ...[
            const SizedBox(height: 10),
            // Tappable row when the school toggle is on; informational only
            // otherwise. The trailing "Record" hint signals it's actionable.
            InkWell(
              onTap: canRecordPayment
                  ? () => RecordPaymentSheet.show(
                        context,
                        studentId: studentId,
                        studentName: studentName,
                        outstandingPence: outstanding,
                        onRecorded: () =>
                            ref.invalidate(sessionDetailProvider(sessionId)),
                      )
                  : null,
              borderRadius: BorderRadius.circular(KsRadius.md),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: canRecordPayment ? KsColors.primaryTint : KsColors.surface2,
                  borderRadius: BorderRadius.circular(KsRadius.md),
                  border: Border.all(
                    color: canRecordPayment
                        ? KsColors.primary.withValues(alpha: 0.3)
                        : KsColors.border,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.payments_outlined,
                        color: canRecordPayment ? KsColors.primaryDeep : KsColors.ink3,
                        size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Outstanding £${(outstanding / 100).toStringAsFixed(2)}',
                          style: TextStyle(
                              color: canRecordPayment ? KsColors.primaryDeep : KsColors.ink,
                              fontWeight: FontWeight.w700)),
                    ),
                    if (canRecordPayment) ...[
                      const Text('Record',
                          style: TextStyle(
                              color: KsColors.primaryDeep,
                              fontWeight: FontWeight.w700,
                              fontSize: 13)),
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_forward_ios,
                          size: 12, color: KsColors.primaryDeep),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          // Quick attendance toggles while the booking is still open.
          if (status == 'booked' || status == 'needs_reassignment')
            _QuickAttendanceRow(bookingId: bookingId, sessionId: sessionId),
          const SizedBox(height: 8),
          InkWell(
            onTap: () => context.push('/instructor/session/$sessionId/assess/$bookingId'),
            borderRadius: BorderRadius.circular(KsRadius.md),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(
                color: KsColors.primaryTint,
                borderRadius: BorderRadius.circular(KsRadius.md),
              ),
              child: const Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 16, color: KsColors.primaryDeep),
                  SizedBox(width: 8),
                  Text('Assess',
                      style: TextStyle(color: KsColors.primaryDeep, fontWeight: FontWeight.w700)),
                  Spacer(),
                  Icon(Icons.arrow_forward_ios, size: 12, color: KsColors.primaryDeep),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String text) => Row(children: [
        Icon(icon, size: 14, color: KsColors.ink3),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(color: KsColors.ink2, fontSize: 13)),
      ]);
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip(this.status);
  @override
  Widget build(BuildContext context) {
    late Color fg, bg;
    late String label;
    switch (status) {
      case 'booked':
        fg = KsColors.primary; bg = KsColors.primaryTint; label = 'Booked'; break;
      case 'needs_reassignment':
        fg = KsColors.warning; bg = KsColors.warningTint; label = 'Reassign'; break;
      case 'completed':
        fg = KsColors.success; bg = KsColors.successTint; label = 'Done'; break;
      case 'no_show':
        fg = KsColors.danger; bg = KsColors.dangerTint; label = 'No-show'; break;
      default:
        fg = KsColors.ink3; bg = KsColors.surface3; label = status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
      child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 11)),
    );
  }
}

class _QuickAttendanceRow extends ConsumerStatefulWidget {
  final String bookingId;
  final String sessionId;
  const _QuickAttendanceRow({required this.bookingId, required this.sessionId});
  @override
  ConsumerState<_QuickAttendanceRow> createState() => _QuickAttendanceRowState();
}

class _QuickAttendanceRowState extends ConsumerState<_QuickAttendanceRow> {
  bool _saving = false;

  Future<void> _mark(String status) async {
    setState(() => _saving = true);
    final api = ref.read(apiClientProvider);
    try {
      await api.markAttendance(bookingId: widget.bookingId, status: status);
      ref.invalidate(sessionDetailProvider(widget.sessionId));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not update attendance'),
          backgroundColor: KsColors.danger,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: OutlinedButton.icon(
          onPressed: _saving ? null : () => _mark('completed'),
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Present'),
          style: OutlinedButton.styleFrom(
            foregroundColor: KsColors.success,
            side: BorderSide(color: KsColors.success.withValues(alpha: 0.4)),
            minimumSize: const Size.fromHeight(36),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: OutlinedButton.icon(
          onPressed: _saving ? null : () => _mark('no_show'),
          icon: const Icon(Icons.close, size: 16),
          label: const Text('No-show'),
          style: OutlinedButton.styleFrom(
            foregroundColor: KsColors.danger,
            side: BorderSide(color: KsColors.danger.withValues(alpha: 0.4)),
            minimumSize: const Size.fromHeight(36),
          ),
        ),
      ),
    ]);
  }
}
