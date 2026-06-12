// Admin Finance — monthly billed vs collected, ageing of outstanding,
// per-course revenue split. All from `charges` and `payments`, voided
// excluded. Bars are drawn natively (no chart library).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

class AdminFinanceScreen extends ConsumerWidget {
  const AdminFinanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(revenueProvider);
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(revenueProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Finance',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  letterSpacing: -0.6)),
          const SizedBox(height: 4),
          const Text(
            'What\'s been billed, what\'s been collected, what\'s still owed.',
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
              title: 'Couldn’t load finance overview',
              message: e.toString(),
            ),
            data: (r) => _Body(report: r),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final RevenueReport report;
  const _Body({required this.report});

  @override
  Widget build(BuildContext context) {
    final last = report.monthly.isEmpty ? null : report.monthly.last;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _HeroStrip(
        billed: last?.billedPence ?? 0,
        collected: last?.collectedPence ?? 0,
        outstanding: report.outstandingPence,
      ),
      const SizedBox(height: 22),
      _Section(
        title: 'Monthly · billed vs collected',
        child: _MonthlyChart(months: report.monthly),
      ),
      const SizedBox(height: 22),
      _Section(
        title: 'Outstanding — ageing',
        child: _AgeingTable(buckets: report.ageing),
      ),
      const SizedBox(height: 22),
      _Section(
        title: 'Revenue by course',
        child: _ByCourseTable(rows: report.byCourse),
      ),
    ]);
  }
}

class _HeroStrip extends StatelessWidget {
  final int billed;
  final int collected;
  final int outstanding;
  const _HeroStrip({
    required this.billed,
    required this.collected,
    required this.outstanding,
  });

  @override
  Widget build(BuildContext context) {
    Widget tile(Color tone, IconData icon, String value, String label,
            {String? sub}) =>
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: KsColors.surface,
            borderRadius: BorderRadius.circular(KsRadius.lg),
            border: Border.all(color: KsColors.border),
            boxShadow: KsShadows.sh1,
          ),
          child: Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(KsRadius.sm),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: tone, size: 20),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: KsColors.ink,
                          height: 1)),
                  const SizedBox(height: 4),
                  Text(label,
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: KsColors.ink)),
                  if (sub != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(sub,
                          style: const TextStyle(
                              color: KsColors.ink3, fontSize: 11.5)),
                    ),
                ],
              ),
            ),
          ]),
        );
    return LayoutBuilder(builder: (ctx, c) {
      final width = c.maxWidth.isFinite ? c.maxWidth : 900.0;
      final cols = width >= 800 ? 3 : 1;
      final spacing = 12.0;
      final tileWidth = ((width - (cols - 1) * spacing) / cols)
          .clamp(220.0, 380.0);
      return Wrap(spacing: spacing, runSpacing: spacing, children: [
        SizedBox(
            width: tileWidth,
            child: tile(KsColors.primary, Icons.receipt_long_outlined,
                _money(billed), 'Billed this month')),
        SizedBox(
            width: tileWidth,
            child: tile(KsColors.success, Icons.payments_outlined,
                _money(collected), 'Collected this month')),
        SizedBox(
            width: tileWidth,
            child: tile(
                outstanding > 0 ? KsColors.danger : KsColors.success,
                Icons.account_balance_wallet_outlined,
                _money(outstanding),
                'Outstanding overall',
                sub: outstanding > 0
                    ? 'Across the whole school'
                    : 'Everyone settled')),
      ]);
    });
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});
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
        child: child,
      ),
    ]);
  }
}

class _MonthlyChart extends StatelessWidget {
  final List<RevenueMonth> months;
  const _MonthlyChart({required this.months});

  @override
  Widget build(BuildContext context) {
    if (months.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text('No revenue activity yet.',
            style: TextStyle(color: KsColors.ink3)),
      );
    }
    final maxValue = months.fold<int>(0, (a, m) {
      final v = m.billedPence > m.collectedPence ? m.billedPence : m.collectedPence;
      return v > a ? v : a;
    });
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _LegendSwatch(color: KsColors.primary, label: 'Billed'),
          const SizedBox(width: 14),
          _LegendSwatch(color: KsColors.success, label: 'Collected'),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          height: 180,
          child: LayoutBuilder(builder: (ctx, c) {
            final barGroup = (c.maxWidth - 8) / months.length;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final m in months)
                  SizedBox(
                    width: barGroup,
                    child: _BarPair(
                      billed: m.billedPence,
                      collected: m.collectedPence,
                      maxValue: maxValue,
                      label: m.month.substring(5), // MM
                    ),
                  ),
              ],
            );
          }),
        ),
      ]),
    );
  }
}

class _BarPair extends StatelessWidget {
  final int billed;
  final int collected;
  final int maxValue;
  final String label;
  const _BarPair({
    required this.billed,
    required this.collected,
    required this.maxValue,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    double frac(int v) => maxValue == 0 ? 0 : v / maxValue;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Bar(value: frac(billed), color: KsColors.primary),
              const SizedBox(width: 4),
              _Bar(value: frac(collected), color: KsColors.success),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: GoogleFonts.plusJakartaSans(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: KsColors.ink3)),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  final double value; // 0..1
  final Color color;
  const _Bar({required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: value.clamp(0.0, 1.0),
      child: Container(
        width: 14,
        decoration: BoxDecoration(
          color: color,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
        ),
      ),
    );
  }
}

class _LegendSwatch extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendSwatch({required this.color, required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(3)),
      ),
      const SizedBox(width: 6),
      Text(label,
          style: const TextStyle(color: KsColors.ink2, fontSize: 12)),
    ]);
  }
}

class _AgeingTable extends StatelessWidget {
  final List<AgeingBucket> buckets;
  const _AgeingTable({required this.buckets});
  @override
  Widget build(BuildContext context) {
    if (buckets.every((b) => b.pence == 0)) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text('Nothing outstanding — everyone\'s settled.',
            style: TextStyle(color: KsColors.success)),
      );
    }
    final maxPence = buckets.fold<int>(0, (a, b) => b.pence > a ? b.pence : a);
    return Column(
      children: [
        for (var i = 0; i < buckets.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: i == buckets.length - 1
                    ? BorderSide.none
                    : const BorderSide(color: KsColors.border),
              ),
            ),
            child: Row(children: [
              SizedBox(
                width: 100,
                child: Text(buckets[i].label,
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700,
                        color: _ageingTone(i),
                        fontSize: 13)),
              ),
              Expanded(
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: KsColors.surface2,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: maxPence == 0 ? 0 : buckets[i].pence / maxPence,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _ageingTone(i),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 100,
                child: Text(_money(buckets[i].pence),
                    textAlign: TextAlign.right,
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: KsColors.ink)),
              ),
            ]),
          ),
      ],
    );
  }

  Color _ageingTone(int idx) {
    switch (idx) {
      case 0:
        return KsColors.success;
      case 1:
        return KsColors.warning;
      case 2:
        return KsColors.warning;
      default:
        return KsColors.danger;
    }
  }
}

class _ByCourseTable extends StatelessWidget {
  final List<RevenueByCourse> rows;
  const _ByCourseTable({required this.rows});
  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text('No course revenue recorded.',
            style: TextStyle(color: KsColors.ink3)),
      );
    }
    return Column(children: [
      for (var i = 0; i < rows.length; i++)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: i == rows.length - 1
                  ? BorderSide.none
                  : const BorderSide(color: KsColors.border),
            ),
          ),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(rows[i].name,
                        style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: KsColors.ink)),
                    const SizedBox(height: 2),
                    Text('${rows[i].code} · ${rows[i].bookingCount} booking${rows[i].bookingCount == 1 ? '' : 's'}',
                        style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
                  ]),
            ),
            Text(_money(rows[i].billedPence),
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: KsColors.ink)),
          ]),
        ),
    ]);
  }
}

String _money(int pence) {
  if (pence == 0) return '£0';
  final negative = pence < 0;
  final abs = pence.abs();
  final whole = abs ~/ 100;
  final f = abs % 100;
  final wholeStr = _thousands(whole);
  final s = f == 0 ? '£$wholeStr' : '£$wholeStr.${f.toString().padLeft(2, '0')}';
  return negative ? '-$s' : s;
}

String _thousands(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
