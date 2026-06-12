// Instructor session detail — header (back / course code+name / QR),
// date+time+location summary card, optional test-day banner, and a
// roster of student cards with avatar, bike, optional phone, safety
// flags, outstanding balance and attendance/assess actions.
//
// Visual structure mirrors the design handoff (`instructor.jsx` →
// `SessionDetail`).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/providers.dart';
import '../state/school.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../util/course_colour.dart';
import '../widgets/ks_avatar.dart';
import '../widgets/record_payment_sheet.dart';
import '../widgets/report_incident_sheet.dart';
import '../widgets/take_bike_offline_sheet.dart';

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
      body: SafeArea(
        bottom: false,
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator(color: KsColors.primary)),
          error: (e, _) => Center(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Couldn’t load.\n$e',
                      style: const TextStyle(color: KsColors.danger)))),
          data: (d) => _Body(data: d, sessionId: sessionId),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final Map<String, dynamic> data;
  final String sessionId;
  const _Body({required this.data, required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookings = ((data['bookings'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final startsAt = DateTime.tryParse(data['startsAt'] ?? '')?.toLocal();
    final endsAt = DateTime.tryParse(data['endsAt'] ?? '')?.toLocal();
    final df = DateFormat('EEE d MMM');
    final tf = DateFormat('HH:mm');
    final nonTeaching = data['nonTeaching'] ?? false;
    final code = (data['courseCode'] ?? '').toString();
    final hex = (data['courseAccentColour'] ?? '').toString();
    final colour = courseColour(code, hex);

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [
        _Header(code: code, colour: colour, name: (data['courseName'] ?? '').toString()),
        const SizedBox(height: 14),
        // Date/time/location summary card.
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: KsColors.surface,
            borderRadius: BorderRadius.circular(KsRadius.lg),
            border: Border.all(color: KsColors.border),
            boxShadow: KsShadows.sh1,
          ),
          child: Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              if (startsAt != null) _meta(Icons.calendar_today_outlined, df.format(startsAt)),
              if (startsAt != null && endsAt != null)
                _meta(Icons.schedule_outlined,
                    '${tf.format(startsAt)}–${tf.format(endsAt)}'),
              if ((data['locationName'] ?? '').toString().isNotEmpty)
                _meta(Icons.place_outlined, (data['locationName'] ?? '').toString()),
            ],
          ),
        ),
        if (nonTeaching) ...[
          const SizedBox(height: 14),
          _NonTeachingBanner(),
        ],
        ..._bikesSection(context, ref, bookings),
        const SizedBox(height: 18),
        _SectionLabel('Roster · ${bookings.length} student${bookings.length == 1 ? '' : 's'}'),
        const SizedBox(height: 8),
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
          for (var i = 0; i < bookings.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _StudentCard(
                b: bookings[i],
                sessionId: sessionId,
                nonTeaching: nonTeaching,
                index: i),
          ],
      ],
    );
  }

  Widget _meta(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: KsColors.ink3),
          const SizedBox(width: 6),
          Text(text,
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: KsColors.ink2)),
        ],
      );

  /// Collects the unique bikes assigned across the session's bookings
  /// and renders one row per bike with a quick "Take offline" action.
  /// Sits above the roster so the instructor's start-of-day check is
  /// a single screen — see the bikes you're using, flag the broken
  /// ones, then move to attendance.
  List<Widget> _bikesSection(
      BuildContext context, WidgetRef ref, List<Map<String, dynamic>> bookings) {
    final seen = <String>{};
    final bikes = <Map<String, String>>[];
    for (final b in bookings) {
      final id = (b['bikeId'] ?? '').toString();
      if (id.isEmpty || seen.contains(id)) continue;
      seen.add(id);
      bikes.add({
        'id': id,
        'nickname': (b['bikeNickname'] ?? '').toString(),
        'reg': (b['bikeRegistration'] ?? '').toString(),
        'studentName': (b['studentName'] ?? '').toString(),
      });
    }
    if (bikes.isEmpty) return const [];
    return [
      const SizedBox(height: 18),
      _SectionLabel('Bikes · ${bikes.length}'),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: KsColors.border),
          boxShadow: KsShadows.sh1,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < bikes.length; i++)
              _BikeRow(
                bike: bikes[i],
                last: i == bikes.length - 1,
                sessionId: sessionId,
              ),
          ],
        ),
      ),
    ];
  }
}

class _BikeRow extends ConsumerWidget {
  final Map<String, String> bike;
  final bool last;
  final String sessionId;
  const _BikeRow({
    required this.bike,
    required this.last,
    required this.sessionId,
  });

  String get _label {
    final n = bike['nickname'] ?? '';
    final r = bike['reg'] ?? '';
    if (n.isEmpty && r.isEmpty) return bike['id'] ?? '';
    if (r.isEmpty) return n;
    if (n.isEmpty) return r;
    return '$n · $r';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = bike['id'] ?? '';
    final student = bike['studentName'] ?? '';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: last
              ? BorderSide.none
              : const BorderSide(color: KsColors.border),
        ),
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
              color: KsColors.primaryDeep, size: 18),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: KsColors.ink)),
              if (student.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text('With $student',
                    style: const TextStyle(
                        color: KsColors.ink3, fontSize: 12.5)),
              ],
            ],
          ),
        ),
        TextButton.icon(
          onPressed: () => TakeBikeOfflineSheet.show(
            context,
            bikeId: id,
            bikeLabel: _label,
            onDone: () => ref.invalidate(sessionDetailProvider(sessionId)),
          ),
          icon: const Icon(Icons.do_not_disturb_on_outlined, size: 16),
          label: const Text('Take offline'),
          style: TextButton.styleFrom(foregroundColor: KsColors.warning),
        ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  final String code;
  final Color colour;
  final String name;
  const _Header({required this.code, required this.colour, required this.name});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _IconButton(icon: Icons.arrow_back, onTap: () => context.pop()),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(code,
                  style: ksMono(
                      size: 10.5,
                      weight: FontWeight.w800,
                      color: colour)),
              const SizedBox(height: 1),
              Text(name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: KsColors.ink,
                      letterSpacing: -0.4,
                      height: 1.05)),
            ],
          ),
        ),
      ],
    );
  }
}

class _IconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _IconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: KsColors.surface,
          border: Border.all(color: KsColors.border),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, color: KsColors.ink2, size: 19),
      ),
    );
  }
}

class _NonTeachingBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KsColors.warningTint,
        borderRadius: BorderRadius.circular(KsRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.flag_outlined, color: KsColors.warning, size: 18),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              'Test day — bike & escort are reserved for the DVA test. No competency assessment to capture.',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: KsColors.ink2,
                  height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: GoogleFonts.plusJakartaSans(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          color: KsColors.ink3,
          letterSpacing: 0.6));
}

class _StudentCard extends ConsumerWidget {
  final Map<String, dynamic> b;
  final String sessionId;
  final bool nonTeaching;
  final int index;
  const _StudentCard({
    required this.b,
    required this.sessionId,
    required this.nonTeaching,
    required this.index,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flags = ((b['safetyFlags'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final phone = (b['studentPhone'] ?? '').toString();
    final bike = (b['bikeNickname'] ?? '').toString();
    final bikeReg = (b['bikeRegistration'] ?? '').toString();
    final bikeId = (b['bikeId'] ?? '').toString();
    final outstanding = (b['outstandingPence'] ?? 0) as int;
    final status = (b['status'] ?? '').toString();
    final bookingId = (b['bookingId'] ?? '').toString();
    final studentId = (b['studentId'] ?? '').toString();
    final studentName = (b['studentName'] ?? '').toString();
    final settings = ref.watch(schoolSettingsProvider).valueOrNull;
    final canRecordPayment =
        (settings?.instructorsCanRecordPayments ?? false) && outstanding > 0;

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
            KsAvatar(name: studentName, size: 42),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(studentName,
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800,
                          color: KsColors.ink,
                          fontSize: 15.5)),
                  if (bike.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Row(children: [
                      const Icon(Icons.two_wheeler, size: 14, color: KsColors.ink3),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(bike,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: KsColors.ink3, fontSize: 12.5)),
                      ),
                      if (bikeReg.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(bikeReg,
                            style: ksMono(
                                size: 11, color: KsColors.ink4)),
                      ],
                    ]),
                  ],
                ],
              ),
            ),
            if (phone.isNotEmpty)
              _phoneButton(phone, studentName)
            else
              _StatusChip(status),
          ]),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(children: [
              Padding(
                padding: const EdgeInsets.only(left: 53),
                child: _StatusChip(status),
              ),
            ]),
          ],
          if (flags.isNotEmpty) ...[
            const SizedBox(height: 11),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: KsColors.warningTint,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in flags)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.shield_outlined,
                              color: KsColors.warning, size: 14),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(f['body'] ?? '',
                                style: GoogleFonts.plusJakartaSans(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: KsColors.ink)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (outstanding > 0) ...[
            const SizedBox(height: 11),
            InkWell(
              onTap: canRecordPayment
                  ? () async {
                      // Belt-and-braces refresh: invalidate from inside
                      // the sheet's callback (catches early closes) AND
                      // again after the sheet returns (catches the case
                      // where Riverpod debounces the in-flight refetch).
                      final result = await RecordPaymentSheet.show(
                        context,
                        studentId: studentId,
                        studentName: studentName,
                        outstandingPence: outstanding,
                        onRecorded: () {
                          ref.invalidate(sessionDetailProvider(sessionId));
                          ref.invalidate(schoolSettingsProvider);
                        },
                      );
                      if (result == true) {
                        // Force a refetch once the sheet has popped so
                        // the just-recorded payment is reflected in the
                        // visible card without a manual pull-to-refresh.
                        ref.invalidate(sessionDetailProvider(sessionId));
                      }
                    }
                  : null,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                decoration: BoxDecoration(
                  color: KsColors.surface2,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  const Icon(Icons.payments_outlined,
                      color: KsColors.ink4, size: 17),
                  const SizedBox(width: 10),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                          style: GoogleFonts.plusJakartaSans(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: KsColors.ink2),
                          children: [
                            const TextSpan(text: 'Outstanding  '),
                            TextSpan(
                                text: '£${(outstanding / 100).toStringAsFixed(2)}',
                                style: const TextStyle(
                                    color: KsColors.danger,
                                    fontWeight: FontWeight.w800)),
                          ]),
                    ),
                  ),
                  if (canRecordPayment)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                      decoration: BoxDecoration(
                        color: KsColors.success,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.add, color: Colors.white, size: 14),
                        const SizedBox(width: 4),
                        Text('Record',
                            style: GoogleFonts.plusJakartaSans(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 12)),
                      ]),
                    ),
                ]),
              ),
            ),
          ] else ...[
            // Positive feedback when the student's all paid up — easier
            // to scan a roster for "who still owes" if Paid lights up
            // green instead of staying silent.
            const SizedBox(height: 11),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: KsColors.successTint,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.check_circle,
                    color: KsColors.success, size: 17),
                const SizedBox(width: 10),
                Text('Paid in full',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: KsColors.success)),
              ]),
            ),
          ],
          const SizedBox(height: 12),
          if (status == 'booked' || status == 'needs_reassignment')
            _AttendanceRow(
              bookingId: bookingId,
              sessionId: sessionId,
              nonTeaching: nonTeaching,
              currentStatus: status,
              onAssess: nonTeaching
                  ? null
                  : () => context.push(
                      '/instructor/session/$sessionId/assess/$bookingId'),
              onReportIncident: () => ReportIncidentSheet.show(
                context,
                bikeId: bikeId,
                bikeLabel: bike.isEmpty
                    ? null
                    : (bikeReg.isEmpty ? bike : '$bike · $bikeReg'),
                studentId: studentId,
                studentName: studentName,
                bookingId: bookingId,
                onLogged: () => ref.invalidate(sessionDetailProvider(sessionId)),
              ),
            )
          else
            _completedFooter(
              nonTeaching: nonTeaching,
              sessionId: sessionId,
              bookingId: bookingId,
              context: context,
              onReportIncident: () => ReportIncidentSheet.show(
                context,
                bikeId: bikeId,
                bikeLabel: bike.isEmpty
                    ? null
                    : (bikeReg.isEmpty ? bike : '$bike · $bikeReg'),
                studentId: studentId,
                studentName: studentName,
                bookingId: bookingId,
                onLogged: () => ref.invalidate(sessionDetailProvider(sessionId)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _completedFooter({
    required bool nonTeaching,
    required String sessionId,
    required String bookingId,
    required BuildContext context,
    required VoidCallback onReportIncident,
  }) {
    if (nonTeaching) {
      // Test day rows still need an incident button — a bike going down
      // during the DVA test is exactly when you'd report it.
      return Row(children: [
        const Icon(Icons.flag_outlined, size: 14, color: KsColors.ink4),
        const SizedBox(width: 5),
        Text('Test day',
            style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: KsColors.ink4)),
        const Spacer(),
        _reportIncidentButton(onReportIncident),
      ]);
    }
    final canOpen = sessionId.isNotEmpty && bookingId.isNotEmpty;
    return Row(children: [
      _reportIncidentButton(onReportIncident),
      const Spacer(),
      TextButton.icon(
        onPressed: canOpen
            ? () => context.push(
                '/instructor/session/$sessionId/assess/$bookingId')
            : null,
        icon: const Icon(Icons.checklist_rounded, size: 16),
        label: const Text('Open assessment'),
        style: TextButton.styleFrom(foregroundColor: KsColors.primaryDeep),
      ),
    ]);
  }

  Widget _reportIncidentButton(VoidCallback onTap) => TextButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.warning_amber_rounded, size: 16),
        label: const Text('Report incident'),
        style: TextButton.styleFrom(foregroundColor: KsColors.warning),
      );

  Widget _phoneButton(String phone, String studentName) {
    return Builder(builder: (context) {
      return InkWell(
        onTap: () async {
          final uri = Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'\s'), ''));
          await launchUrl(uri);
        },
        borderRadius: BorderRadius.circular(11),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: KsColors.surface,
            border: Border.all(color: KsColors.border),
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(Icons.phone, color: KsColors.primary, size: 17),
        ),
      );
    });
  }
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

class _AttendanceRow extends ConsumerStatefulWidget {
  final String bookingId;
  final String sessionId;
  final bool nonTeaching;
  final String currentStatus;
  final VoidCallback? onAssess;
  final VoidCallback onReportIncident;
  const _AttendanceRow({
    required this.bookingId,
    required this.sessionId,
    required this.nonTeaching,
    required this.currentStatus,
    required this.onAssess,
    required this.onReportIncident,
  });
  @override
  ConsumerState<_AttendanceRow> createState() => _AttendanceRowState();
}

class _AttendanceRowState extends ConsumerState<_AttendanceRow> {
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
    final isPresent = widget.currentStatus == 'completed';
    final isNoShow = widget.currentStatus == 'no_show';
    return Row(children: [
      _attendBtn(
        active: isPresent,
        tone: KsColors.success,
        icon: Icons.check,
        label: 'Present',
        onTap: _saving ? null : () => _mark('completed'),
      ),
      const SizedBox(width: 8),
      _attendBtn(
        active: isNoShow,
        tone: KsColors.danger,
        icon: Icons.close,
        label: 'No-show',
        onTap: _saving ? null : () => _mark('no_show'),
      ),
      const Spacer(),
      // Always-available "Report incident" sits to the left of the
      // assess action so the destructive-adjacent button doesn't move
      // around depending on attendance / test-day state.
      TextButton.icon(
        onPressed: widget.onReportIncident,
        icon: const Icon(Icons.warning_amber_rounded, size: 16),
        label: const Text('Report'),
        style: TextButton.styleFrom(foregroundColor: KsColors.warning),
      ),
      if (widget.nonTeaching)
        Row(children: [
          const Icon(Icons.flag_outlined, size: 14, color: KsColors.ink4),
          const SizedBox(width: 5),
          Text('Test day',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink4)),
        ])
      else if (widget.onAssess != null)
        TextButton.icon(
          onPressed: widget.onAssess,
          icon: const Icon(Icons.checklist_rounded, size: 16),
          label: const Text('Assess'),
          style: TextButton.styleFrom(foregroundColor: KsColors.primaryDeep),
        ),
    ]);
  }

  Widget _attendBtn({
    required bool active,
    required Color tone,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: active ? tone : KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.sm),
          border: active ? null : Border.all(color: KsColors.border2),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: active ? Colors.white : KsColors.ink3),
          const SizedBox(width: 6),
          Text(label,
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: active ? Colors.white : KsColors.ink3)),
        ]),
      ),
    );
  }
}

