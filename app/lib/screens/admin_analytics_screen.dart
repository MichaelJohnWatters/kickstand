// Admin Analytics — operational dashboard answering "are bikes and
// instructors earning their keep, and are students getting through
// the licensing funnel?" Revenue + ageing live on /admin/finance and
// are linked from here rather than duplicated.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

class AdminAnalyticsScreen extends ConsumerWidget {
  const AdminAnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async {
        ref.invalidate(bikeUtilisationProvider);
        ref.invalidate(instructorUtilisationProvider);
        ref.invalidate(funnelStatsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: const [
          _Header(),
          SizedBox(height: 18),
          _RangeChips(),
          SizedBox(height: 20),
          _RevenueLink(),
          SizedBox(height: 16),
          _BikeUtilisationCard(),
          SizedBox(height: 16),
          _InstructorUtilisationCard(),
          SizedBox(height: 16),
          _FunnelCard(),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Analytics',
            style: GoogleFonts.plusJakartaSans(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: KsColors.ink,
                letterSpacing: -0.6)),
        const SizedBox(height: 6),
        const Text(
          'Bike and instructor utilisation plus the student licensing '
          'funnel. Money lives on the Finance page so the numbers stay '
          'in one place.',
          style: TextStyle(color: KsColors.ink3, fontSize: 13),
        ),
      ],
    );
  }
}

class _RangeChips extends ConsumerWidget {
  const _RangeChips();

  static const _presets = [7, 30, 90, 365];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final win = ref.watch(analyticsWindowProvider);
    final activeDays = win.to.difference(win.from).inDays;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final days in _presets)
          _Chip(
            label: days == 365 ? 'Last year' : 'Last $days days',
            selected: (activeDays - days).abs() <= 1,
            onTap: () {
              final now = DateTime.now().toUtc();
              ref.read(analyticsWindowProvider.notifier).state =
                  AnalyticsWindow(from: now.subtract(Duration(days: days)), to: now);
            },
          ),
        _Chip(
          label: _formatRange(win),
          selected: false,
          onTap: () => _pickRange(context, ref, win),
          subtle: true,
        ),
      ],
    );
  }

  Future<void> _pickRange(BuildContext context, WidgetRef ref, AnalyticsWindow win) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: win.from, end: win.to),
    );
    if (picked != null) {
      ref.read(analyticsWindowProvider.notifier).state =
          AnalyticsWindow(from: picked.start.toUtc(), to: picked.end.toUtc());
    }
  }

  String _formatRange(AnalyticsWindow w) {
    final f = DateFormat('d MMM');
    return 'Custom · ${f.format(w.from)} – ${f.format(w.to)}';
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool subtle;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtle = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? KsColors.primary
        : (subtle ? KsColors.surface2 : KsColors.surface);
    final fg = selected ? Colors.white : KsColors.ink2;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: selected ? KsColors.primary : KsColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.w600, fontSize: 12)),
        ),
      ),
    );
  }
}

class _RevenueLink extends StatelessWidget {
  const _RevenueLink();

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: KsColors.successTint,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.payments_outlined, color: KsColors.success),
        ),
        title: Text('Revenue + ageing',
            style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700, color: KsColors.ink)),
        subtitle: const Text(
            'Charged · paid · outstanding by month, plus aged-debt buckets.',
            style: TextStyle(color: KsColors.ink3, fontSize: 12)),
        trailing: const Icon(Icons.arrow_forward_ios,
            size: 14, color: KsColors.ink3),
        onTap: () => context.go('/admin/finance'),
      ),
    );
  }
}

// ----- Bike utilisation -----

class _BikeUtilisationCard extends ConsumerWidget {
  const _BikeUtilisationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(bikeUtilisationProvider);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(label: 'Bike utilisation', icon: Icons.two_wheeler),
          const SizedBox(height: 4),
          const Text(
            'Booked minutes vs an 8h/day rolling baseline. Above 100% means '
            'the bike is over-subscribed — a real signal, not a bug.',
            style: TextStyle(color: KsColors.ink3, fontSize: 12),
          ),
          const SizedBox(height: 12),
          async.when(
            loading: () => const _SectionLoading(),
            error: (e, _) => KsEmptyState.error(message: e.toString()),
            data: (rows) {
              if (rows.isEmpty) {
                return const _EmptyInRange(label: 'No bikes registered yet.');
              }
              return Column(children: [for (final r in rows) _BikeRow(row: r)]);
            },
          ),
        ],
      ),
    );
  }
}

class _BikeRow extends StatelessWidget {
  final BikeUtilisationRow row;
  const _BikeRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final pct = row.utilisationPct.clamp(0, 200).toDouble();
    final barColour = pct < 30
        ? KsColors.ink4
        : pct < 70
            ? KsColors.success
            : pct < 100
                ? KsColors.warning
                : KsColors.danger;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                row.nickname.isEmpty ? row.bikeId : row.nickname,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, color: KsColors.ink),
              ),
            ),
            if (row.registration.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(row.registration,
                    style: GoogleFonts.spaceMono(
                        color: KsColors.ink3, fontSize: 12)),
              ),
            Text('${row.utilisationPct.toStringAsFixed(0)}%',
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: barColour)),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (pct / 100).clamp(0, 1).toDouble(),
              minHeight: 6,
              backgroundColor: KsColors.surface3,
              valueColor: AlwaysStoppedAnimation(barColour),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${row.sessionsCount} sessions · ${(row.bookedMinutes / 60).toStringAsFixed(1)} h booked'
            ' of ${(row.availableMinutes / 60).toStringAsFixed(0)} h available',
            style: const TextStyle(color: KsColors.ink3, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ----- Instructor utilisation -----

class _InstructorUtilisationCard extends ConsumerWidget {
  const _InstructorUtilisationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(instructorUtilisationProvider);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(label: 'Instructor utilisation', icon: Icons.groups_2),
          const SizedBox(height: 4),
          const Text(
            'Sessions taught + earnings inside the window. Outstanding is the '
            'all-time snapshot (matches the Instructor pay screen).',
            style: TextStyle(color: KsColors.ink3, fontSize: 12),
          ),
          const SizedBox(height: 12),
          async.when(
            loading: () => const _SectionLoading(),
            error: (e, _) => KsEmptyState.error(message: e.toString()),
            data: (rows) {
              if (rows.isEmpty) {
                return const _EmptyInRange(label: 'No instructors yet.');
              }
              return Column(
                  children: [for (final r in rows) _InstructorRow(row: r)]);
            },
          ),
        ],
      ),
    );
  }
}

class _InstructorRow extends StatelessWidget {
  final InstructorUtilisationRow row;
  const _InstructorRow({required this.row});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.name.isEmpty ? row.instructorId : row.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: KsColors.ink)),
                const SizedBox(height: 2),
                Text(
                    '${row.sessionsTaught} sessions · ${row.hoursTaught.toStringAsFixed(1)} h',
                    style:
                        const TextStyle(color: KsColors.ink3, fontSize: 11)),
              ],
            ),
          ),
          SizedBox(width: 80, height: 36, child: _Sparkline(values: row.weeklyTrend)),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_pounds(row.earnedPence),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: KsColors.ink)),
                Text(
                    'paid ${_pounds(row.paidPence)} · owed ${_pounds(row.outstandingPence)}',
                    style:
                        const TextStyle(color: KsColors.ink3, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sparkline extends StatelessWidget {
  final List<int> values;
  const _Sparkline({required this.values});

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty || values.every((v) => v == 0)) {
      return const Center(
        child: Text('—',
            style: TextStyle(color: KsColors.ink4, fontSize: 11)),
      );
    }
    final maxV = values.reduce((a, b) => a > b ? a : b).toDouble();
    final spots = <FlSpot>[
      for (var i = 0; i < values.length; i++)
        FlSpot(i.toDouble(), values[i].toDouble()),
    ];
    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxV == 0 ? 1 : maxV,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            barWidth: 2,
            color: KsColors.primary,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: KsColors.primaryTint,
            ),
          ),
        ],
      ),
    );
  }
}

// ----- Funnel -----

class _FunnelCard extends ConsumerWidget {
  const _FunnelCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(funnelStatsProvider);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(label: 'Funnel', icon: Icons.signal_cellular_alt),
          const SizedBox(height: 4),
          const Text(
            'Where students are getting through and where they\'re stalling.',
            style: TextStyle(color: KsColors.ink3, fontSize: 12),
          ),
          const SizedBox(height: 12),
          async.when(
            loading: () => const _SectionLoading(),
            error: (e, _) => KsEmptyState.error(message: e.toString()),
            data: (fs) => _FunnelBody(stats: fs),
          ),
        ],
      ),
    );
  }
}

class _FunnelBody extends StatelessWidget {
  final FunnelStats stats;
  const _FunnelBody({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatTile(
              label: 'Signup → first booking',
              pct: stats.signupToFirstBookingPct,
              sample: stats.signupSample,
              hint: 'within 30 days',
            ),
            _StatTile(
              label: 'CBT completion',
              pct: stats.cbtCompletionPct,
              sample: stats.cbtSample,
              hint: 'of in-window CBT bookings',
            ),
            _StatTile(
              label: 'Theory pass rate',
              pct: stats.theoryPassPct,
              sample: stats.theorySample,
              hint: 'of decided attempts',
            ),
            _StatTile(
              label: 'Practical pass rate',
              pct: stats.practicalPassPct,
              sample: stats.practicalSample,
              hint: 'of decided attempts',
            ),
          ],
        ),
        if (stats.perInstructorPassRate.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('Pass rate by instructor (last instructor before the test)',
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700,
                  color: KsColors.ink2,
                  fontSize: 13)),
          const SizedBox(height: 8),
          for (final p in stats.perInstructorPassRate) _PassRateRow(rate: p),
        ],
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final double pct;
  final int sample;
  final String hint;
  const _StatTile({
    required this.label,
    required this.pct,
    required this.sample,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final hasData = sample > 0;
    return Container(
      width: 200,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: KsColors.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: KsColors.ink3,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            hasData ? '${pct.toStringAsFixed(0)}%' : '—',
            style: GoogleFonts.plusJakartaSans(
                color: KsColors.ink,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.8),
          ),
          const SizedBox(height: 4),
          Text(hasData ? '$sample · $hint' : 'No data in range',
              style: const TextStyle(color: KsColors.ink3, fontSize: 11)),
        ],
      ),
    );
  }
}

class _PassRateRow extends StatelessWidget {
  final InstructorPassRate rate;
  const _PassRateRow({required this.rate});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Text(rate.name,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: KsColors.ink)),
        ),
        Text('${rate.passes}/${rate.attempts}',
            style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
        const SizedBox(width: 12),
        SizedBox(
          width: 50,
          child: Text('${rate.passPct.toStringAsFixed(0)}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: rate.passPct >= 70 ? KsColors.success : KsColors.warning)),
        ),
      ]),
    );
  }
}

// ----- shared bits -----

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: KsColors.border),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SectionTitle({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 18, color: KsColors.ink2),
      const SizedBox(width: 8),
      Text(label,
          style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w800,
              fontSize: 18,
              color: KsColors.ink,
              letterSpacing: -0.3)),
    ]);
  }
}

class _SectionLoading extends StatelessWidget {
  const _SectionLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
    );
  }
}

class _EmptyInRange extends StatelessWidget {
  final String label;
  const _EmptyInRange({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(label,
          style: const TextStyle(color: KsColors.ink3, fontSize: 13)),
    );
  }
}

String _pounds(int pence) {
  if (pence == 0) return '£0';
  final pounds = pence / 100.0;
  return '£${pounds.toStringAsFixed(pence % 100 == 0 ? 0 : 2)}';
}
