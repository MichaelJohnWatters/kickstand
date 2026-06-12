// Admin Compliance — single-pane view of every expiry the school is on
// the hook for: bike MOT/tax, instructor accreditation, school insurance.
//
// Severity buckets come pre-computed from the backend (re-uses the same
// thresholds as the fleet docs filters). The page sorts by severity so
// expired items always sit at the top.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

class AdminComplianceScreen extends ConsumerWidget {
  const AdminComplianceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(complianceProvider);
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(complianceProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Compliance',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  letterSpacing: -0.6)),
          const SizedBox(height: 4),
          const Text(
            'Bike documents, instructor accreditation, and school insurance — '
            'everything with a date the law cares about.',
            style: TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 18),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                  child:
                      CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => KsEmptyState.error(
              title: 'Couldn’t load compliance',
              message: e.toString(),
            ),
            data: (r) => _Body(report: r),
          ),
        ],
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final ComplianceReport report;
  const _Body({required this.report});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sortedBikes = [...report.bikes]
      ..sort((a, b) => _severity(b.worstStatus).compareTo(_severity(a.worstStatus)));
    final sortedInstructors = [...report.instructors]
      ..sort((a, b) =>
          _severity(b.worstStatus).compareTo(_severity(a.worstStatus)));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _SummaryStrip(report: report),
      const SizedBox(height: 22),
      _Section(
        title: 'School insurance',
        children: [
          _InsuranceCard(report: report),
        ],
      ),
      const SizedBox(height: 22),
      _Section(
        title: 'Bikes',
        empty: 'No bikes recorded.',
        children: sortedBikes.map((b) => _BikeRow(bike: b)).toList(),
      ),
      const SizedBox(height: 22),
      _Section(
        title: 'Instructor accreditation',
        empty: 'No instructors recorded.',
        children: sortedInstructors
            .map((i) => _InstructorRow(instructor: i))
            .toList(),
      ),
    ]);
  }
}

int _severity(String s) {
  switch (s) {
    case 'expired':
      return 4;
    case 'due_urgent':
      return 3;
    case 'due_soon':
      return 2;
    case 'ok':
      return 1;
  }
  return 0; // unknown
}

(Color, Color, String) _toneAndLabel(String status, String date) {
  switch (status) {
    case 'expired':
      return (KsColors.danger, KsColors.dangerTint,
          date.isEmpty ? 'Expired' : 'Expired $date');
    case 'due_urgent':
      return (KsColors.danger, KsColors.dangerTint,
          date.isEmpty ? 'Urgent' : 'Urgent · $date');
    case 'due_soon':
      return (KsColors.warning, KsColors.warningTint,
          date.isEmpty ? 'Due soon' : 'Due $date');
    case 'ok':
      return (KsColors.success, KsColors.successTint,
          date.isEmpty ? 'OK' : 'OK · $date');
  }
  return (KsColors.ink3, KsColors.surface3, 'Unknown');
}

class _SummaryStrip extends StatelessWidget {
  final ComplianceReport report;
  const _SummaryStrip({required this.report});

  @override
  Widget build(BuildContext context) {
    final allClear = report.expiredCount == 0 &&
        report.urgentCount == 0 &&
        report.warnCount == 0;
    return LayoutBuilder(builder: (ctx, c) {
      final width = c.maxWidth.isFinite ? c.maxWidth : 900.0;
      final cols = width >= 800 ? 4 : 2;
      final tileWidth = ((width - (cols - 1) * 12) / cols).clamp(140.0, 320.0);
      Widget tile(Color tone, IconData icon, int n, String label) =>
          SizedBox(
            width: tileWidth,
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
                  width: 36, height: 36,
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
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (allClear)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: KsColors.successTint,
              borderRadius: BorderRadius.circular(KsRadius.lg),
              border: Border.all(color: KsColors.success.withValues(alpha: 0.4)),
            ),
            child: Row(children: [
              const Icon(Icons.check_circle_outline, color: KsColors.success),
              const SizedBox(width: 10),
              Expanded(
                child: Text('All clear — nothing expiring soon.',
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700, color: KsColors.ink)),
              ),
            ]),
          )
        else
          Wrap(spacing: 12, runSpacing: 12, children: [
            tile(KsColors.danger, Icons.warning_amber_rounded,
                report.expiredCount, 'Expired'),
            tile(KsColors.danger, Icons.priority_high_rounded,
                report.urgentCount, 'Urgent'),
            tile(KsColors.warning, Icons.schedule_rounded,
                report.warnCount, 'Due soon'),
            tile(KsColors.ink3, Icons.help_outline_rounded,
                report.unknownCount, 'Unknown'),
          ]),
      ]);
    });
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final String empty;
  const _Section({required this.title, required this.children, this.empty = ''});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title.toUpperCase(),
          style: GoogleFonts.plusJakartaSans(
              color: KsColors.ink3,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6)),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: KsColors.border),
          boxShadow: KsShadows.sh1,
        ),
        clipBehavior: Clip.antiAlias,
        child: children.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(empty.isEmpty ? '—' : empty,
                    style: const TextStyle(color: KsColors.ink3)),
              )
            : Column(children: children),
      ),
    ]);
  }
}

class _BikeRow extends ConsumerWidget {
  final ComplianceBike bike;
  const _BikeRow({required this.bike});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (motFg, motBg, motLabel) =
        _toneAndLabel(bike.motStatus, bike.motExpiresOn);
    final (taxFg, taxBg, taxLabel) =
        _toneAndLabel(bike.taxStatus, bike.taxExpiresOn);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: KsColors.border)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(bike.nickname.isEmpty ? bike.id : bike.nickname,
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: KsColors.ink)),
            if (bike.registration.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(bike.registration,
                    style: const TextStyle(
                        color: KsColors.ink3, fontSize: 12)),
              ),
          ]),
        ),
        _Pill(fg: motFg, bg: motBg, label: 'MOT · $motLabel'),
        const SizedBox(width: 8),
        _Pill(fg: taxFg, bg: taxBg, label: 'Tax · $taxLabel'),
      ]),
    );
  }
}

class _InstructorRow extends StatelessWidget {
  final ComplianceInstructor instructor;
  const _InstructorRow({required this.instructor});

  @override
  Widget build(BuildContext context) {
    final (fg, bg, label) = _toneAndLabel(instructor.worstStatus, '');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: KsColors.border)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(instructor.name,
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: KsColors.ink)),
          ),
          _Pill(fg: fg, bg: bg, label: label),
        ]),
        if (instructor.accreditations.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'No accreditations on file — edit on the Instructors page.',
              style: TextStyle(color: KsColors.ink3, fontSize: 12, fontStyle: FontStyle.italic),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final a in instructor.accreditations)
                _coursePill(a),
            ]),
          ),
      ]),
    );
  }

  Widget _coursePill(ComplianceAccreditation a) {
    final (fg, bg, _) = _toneAndLabel(a.status, a.expiresOn);
    final dateLabel = a.expiresOn.isEmpty ? 'No date' : a.expiresOn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text('${a.courseCode} · $dateLabel',
          style: GoogleFonts.plusJakartaSans(
              color: fg, fontWeight: FontWeight.w700, fontSize: 11.5)),
    );
  }
}

class _InsuranceCard extends ConsumerStatefulWidget {
  final ComplianceReport report;
  const _InsuranceCard({required this.report});
  @override
  ConsumerState<_InsuranceCard> createState() => _InsuranceCardState();
}

class _InsuranceCardState extends ConsumerState<_InsuranceCard> {
  bool _busy = false;

  Future<void> _pick() async {
    final initial =
        DateTime.tryParse(widget.report.insuranceExpiresOn) ??
            DateTime.now().add(const Duration(days: 365));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(initial.year - 5),
      lastDate: DateTime(initial.year + 10),
    );
    if (picked == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).setInsurance(expiresOn: _isoDate(picked));
      ref.invalidate(complianceProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not save: $e'),
            backgroundColor: KsColors.danger));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (fg, bg, label) = _toneAndLabel(
        widget.report.insuranceStatus, widget.report.insuranceExpiresOn);
    return InkWell(
      onTap: _busy ? null : _pick,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Policy renewal',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: KsColors.ink)),
              const SizedBox(height: 2),
              const Text(
                'Public liability + fleet cover. Tap to edit.',
                style: TextStyle(color: KsColors.ink3, fontSize: 12),
              ),
            ]),
          ),
          if (_busy)
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
          else
            _Pill(fg: fg, bg: bg, label: label),
          const SizedBox(width: 6),
          const Icon(Icons.edit_outlined, size: 14, color: KsColors.ink4),
        ]),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final Color fg;
  final Color bg;
  final String label;
  const _Pill({required this.fg, required this.bg, required this.label});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text(label,
          style: GoogleFonts.plusJakartaSans(
              color: fg, fontWeight: FontWeight.w700, fontSize: 11.5)),
    );
  }
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
