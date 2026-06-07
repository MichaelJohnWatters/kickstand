// Admin Overview — personalised greeting, 4 KPI tiles, "needs attention" +
// "today's sessions" two-column body. Matches design/admin.jsx:103.
//
// Data sources:
//   - /calendar today → sessions today + instructors on today
//   - /calendar this week → occupancy %
//   - /bikes → ready / fleet counts
//   - /instructors → instructor count
//   - /signups/pending → pending count (sidebar badge reuse)
//   - /disruptions → open disruption count
//   - /logistics tomorrow → bikes-to-move count

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../state/providers.dart';
import '../theme/tokens.dart';

final _todaySessionsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.read(apiClientProvider);
  final now = DateTime.now();
  final from = DateTime(now.year, now.month, now.day);
  final to = from.add(const Duration(days: 1));
  return api.calendar(from: from, to: to);
});

final _weekSessionsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.read(apiClientProvider);
  final now = DateTime.now();
  // Monday of current week.
  final monday = DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: now.weekday - 1));
  final to = monday.add(const Duration(days: 7));
  return api.calendar(from: monday, to: to);
});

class AdminOverviewScreen extends ConsumerWidget {
  const AdminOverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(authControllerProvider).identity;
    final firstName = (identity?.name.split(' ').first ?? 'there');
    final greeting = _greetingFor(DateTime.now());
    final dateLabel = DateFormat('EEEE d MMMM').format(DateTime.now());

    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async {
        ref.invalidate(_todaySessionsProvider);
        ref.invalidate(_weekSessionsProvider);
        ref.invalidate(fleetProvider);
        ref.invalidate(instructorsProvider);
        ref.invalidate(openDisruptionsProvider);
        ref.invalidate(logisticsForDateProvider);
        ref.invalidate(pendingSignupsCountProvider);
      },
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('$greeting, $firstName',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  letterSpacing: -0.6)),
          const SizedBox(height: 4),
          Text("$dateLabel · here’s how today looks.",
              style: const TextStyle(color: KsColors.ink3, fontSize: 13)),
          const SizedBox(height: 22),
          const _KpiGrid(),
          const SizedBox(height: 22),
          const _Body(),
        ],
      ),
    );
  }
}

String _greetingFor(DateTime t) {
  final h = t.hour;
  if (h < 12) return 'Good morning';
  if (h < 18) return 'Good afternoon';
  return 'Good evening';
}

// ===== KPI grid =====

class _KpiGrid extends ConsumerWidget {
  const _KpiGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(_todaySessionsProvider);
    final week = ref.watch(_weekSessionsProvider);
    final fleet = ref.watch(fleetProvider);
    final instructors = ref.watch(instructorsProvider);

    final sessionsTodayCount = today.maybeWhen(
        data: (list) => list.length, orElse: () => null);
    final activeSites = today.maybeWhen(
        data: (list) =>
            list.map((s) => s['locationId']).whereType<String>().toSet().length,
        orElse: () => 0);

    final bikes = fleet.valueOrNull;
    final bikesReady = bikes?.where((b) => b.status == 'ready').length;
    final bikesTotal = bikes?.length;

    final instructorList = instructors.valueOrNull;
    final instructorTotal = instructorList?.length;
    final instructorsOnToday = today.maybeWhen(
        data: (list) =>
            list.map((s) => s['instructorId']).whereType<String>().toSet().length,
        orElse: () => null);

    final occupancyPct = week.maybeWhen(data: (list) {
      if (list.isEmpty) return null;
      var booked = 0;
      var cap = 0;
      for (final s in list) {
        booked += (s['activeBookings'] as num?)?.toInt() ?? 0;
        cap += (s['capacity'] as num?)?.toInt() ?? 0;
      }
      if (cap == 0) return 0;
      return ((booked / cap) * 100).round();
    }, orElse: () => null);

    return LayoutBuilder(builder: (ctx, c) {
      final available = c.maxWidth.isFinite ? c.maxWidth : 900.0;
      final cols = available >= 1100 ? 4 : available >= 700 ? 2 : 1;
      final width = ((available - (cols - 1) * 14) / cols).clamp(160.0, 400.0);
      return Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [
          SizedBox(
            width: width,
            child: _KpiTile(
              icon: Icons.calendar_today_rounded,
              tone: KsColors.primary,
              value: sessionsTodayCount?.toString() ?? '—',
              label: 'Sessions today',
              foot: activeSites == 0
                  ? 'No sites active'
                  : '$activeSites site${activeSites == 1 ? '' : 's'} active',
              loading: today.isLoading,
            ),
          ),
          SizedBox(
            width: width,
            child: _KpiTile(
              icon: Icons.check_circle_outline,
              tone: KsColors.success,
              value: bikesReady == null ? '—' : '$bikesReady',
              label: 'Bikes ready',
              foot: bikesTotal == null ? '' : 'of $bikesTotal in fleet',
              loading: fleet.isLoading,
            ),
          ),
          SizedBox(
            width: width,
            child: _KpiTile(
              icon: Icons.group_outlined,
              tone: KsColors.warning,
              value: instructorsOnToday?.toString() ??
                  (instructorTotal?.toString() ?? '—'),
              label: 'Instructors on',
              foot: instructorTotal == null
                  ? ''
                  : 'of $instructorTotal staff',
              loading: instructors.isLoading,
            ),
          ),
          SizedBox(
            width: width,
            child: _KpiTile(
              icon: Icons.speed_outlined,
              tone: KsColors.danger,
              value: occupancyPct == null ? '—' : '$occupancyPct%',
              label: 'Week occupancy',
              foot: 'across all sessions',
              loading: week.isLoading,
            ),
          ),
        ],
      );
    });
  }
}

class _KpiTile extends StatelessWidget {
  final IconData icon;
  final Color tone;
  final String value;
  final String label;
  final String foot;
  final bool loading;
  const _KpiTile({
    required this.icon,
    required this.tone,
    required this.value,
    required this.label,
    required this.foot,
    required this.loading,
  });

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
          Row(
            children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(KsRadius.sm),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: tone, size: 20),
              ),
              const Spacer(),
              if (loading)
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        color: KsColors.ink3, strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 14),
          Text(value,
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  letterSpacing: -0.8,
                  height: 1)),
          const SizedBox(height: 4),
          Text(label,
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: KsColors.ink)),
          if (foot.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(foot,
                style:
                    const TextStyle(color: KsColors.ink4, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

// ===== Two-column body =====

class _Body extends StatelessWidget {
  const _Body();
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final wide = c.maxWidth.isFinite && c.maxWidth >= 900;
      if (wide) {
        // Design: 1.4fr / 1fr
        const leftFlex = 14;
        const rightFlex = 10;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Expanded(flex: leftFlex, child: _NeedsAttention()),
            SizedBox(width: 18),
            Expanded(flex: rightFlex, child: _TodaySessions()),
          ],
        );
      }
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _NeedsAttention(),
          SizedBox(height: 18),
          _TodaySessions(),
        ],
      );
    });
  }
}

// ===== Needs attention =====

class _NeedsAttention extends ConsumerWidget {
  const _NeedsAttention();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final disruptions = ref.watch(openDisruptionsProvider);
    final logistics = ref.watch(tomorrowLogisticsProvider);
    final pending = ref.watch(pendingSignupsCountProvider);

    final disruptionList = disruptions.valueOrNull ?? const [];
    final openDisruptions = disruptionList.where((d) {
      // Treat anything without resolved_at as open.
      final rs = (d['resolvedAt'] ?? '').toString();
      return rs.isEmpty;
    }).toList();

    final movesCount = (logistics.valueOrNull?['totalMoves'] as num?)?.toInt() ?? 0;
    final pendingCount = pending;

    final cards = <Widget>[];
    if (openDisruptions.isNotEmpty) {
      cards.add(_AttentionCard(
        tone: KsColors.danger,
        icon: Icons.warning_amber_rounded,
        title: openDisruptions.length == 1
            ? _disruptionTitle(openDisruptions.first)
            : '${openDisruptions.length} bike disruptions open',
        subtitle: openDisruptions.length == 1
            ? _disruptionSubtitle(openDisruptions.first)
            : 'Affected bookings need swapping or cancelling.',
        cta: 'Resolve',
        ctaPrimary: true,
        onTap: () => context.go('/admin/disruptions'),
        accent: true,
      ));
    }
    if (movesCount > 0) {
      cards.add(_AttentionCard(
        tone: KsColors.warning,
        icon: Icons.route_outlined,
        title: '$movesCount bike${movesCount == 1 ? '' : 's'} need moving for tomorrow',
        subtitle: 'Cross-site moves before tomorrow’s first session.',
        cta: '',
        ctaPrimary: false,
        onTap: () => context.go('/admin/logistics'),
      ));
    }
    if (pendingCount > 0) {
      cards.add(_AttentionCard(
        tone: KsColors.warning,
        icon: Icons.person_add_outlined,
        title: '$pendingCount sign-up${pendingCount == 1 ? '' : 's'} waiting',
        subtitle: 'Review and approve so students can book.',
        cta: '',
        ctaPrimary: false,
        onTap: () => context.go('/admin/signups'),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionLabel(text: 'NEEDS ATTENTION'),
        const SizedBox(height: 8),
        if (cards.isEmpty)
          _AllClearCard()
        else
          ...cards.map((c) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: c,
              )),
      ],
    );
  }

  String _disruptionTitle(Map<String, dynamic> d) {
    final nick = (d['bikeNickname'] ?? '').toString();
    final reg = (d['bikeRegistration'] ?? '').toString();
    final at = (d['bikeLocationName'] ?? d['locationName'] ?? '').toString();
    final bike = nick.isNotEmpty ? nick : (reg.isNotEmpty ? reg : 'A bike');
    return at.isEmpty ? '$bike is down' : '$bike down at $at';
  }

  String _disruptionSubtitle(Map<String, dynamic> d) {
    final affected = ((d['affectedBookings'] as List?) ?? const []).length;
    final swapped = ((d['affectedBookings'] as List?) ?? const [])
        .where((b) => (b is Map && (b['resolution'] ?? '') == 'swapped'))
        .length;
    if (affected == 0) return 'No bookings affected — restore when fixed.';
    return '$affected booking${affected == 1 ? '' : 's'} affected'
        '${swapped > 0 ? ' · $swapped swapped' : ''}';
  }
}

class _AttentionCard extends StatelessWidget {
  final Color tone;
  final IconData icon;
  final String title;
  final String subtitle;
  final String cta;
  final bool ctaPrimary;
  final bool accent;
  final VoidCallback onTap;
  const _AttentionCard({
    required this.tone,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.cta,
    required this.ctaPrimary,
    required this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = accent
        ? tone.withValues(alpha: 0.08)
        : KsColors.surface;
    final borderColour = accent
        ? tone.withValues(alpha: 0.45)
        : KsColors.border;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.lg),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: borderColour),
          boxShadow: accent ? null : KsShadows.sh1,
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: accent ? tone : tone.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(KsRadius.md),
              ),
              alignment: Alignment.center,
              child: Icon(icon,
                  color: accent ? Colors.white : tone, size: 22),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: KsColors.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: KsColors.ink2, fontSize: 12.5),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (cta.isNotEmpty)
              ElevatedButton(
                onPressed: onTap,
                style: ElevatedButton.styleFrom(
                  backgroundColor: tone,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  minimumSize: const Size(64, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  textStyle: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, fontSize: 12.5),
                ),
                child: Text(cta),
              )
            else
              const Icon(Icons.chevron_right_rounded,
                  color: KsColors.ink4, size: 22),
          ],
        ),
      ),
    );
  }
}

class _AllClearCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: KsColors.successTint,
              borderRadius: BorderRadius.circular(KsRadius.sm),
            ),
            child: const Icon(Icons.check_circle_outline,
                color: KsColors.success, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('All clear',
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800, fontSize: 14.5)),
                const SizedBox(height: 2),
                const Text(
                  'No disruptions, moves, or sign-ups waiting on you.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===== Today's sessions =====

class _TodaySessions extends ConsumerWidget {
  const _TodaySessions();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_todaySessionsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: _SectionLabel(text: "TODAY’S SESSIONS")),
            TextButton(
              onPressed: () => context.go('/admin/calendar'),
              style: TextButton.styleFrom(
                  foregroundColor: KsColors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: Text('Calendar →',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: KsColors.surface,
            borderRadius: BorderRadius.circular(KsRadius.lg),
            border: Border.all(color: KsColors.border),
            boxShadow: KsShadows.sh1,
          ),
          clipBehavior: Clip.antiAlias,
          child: async.when(
            loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                    child: CircularProgressIndicator(color: KsColors.primary))),
            error: (e, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Couldn’t load.\n$e',
                    style: const TextStyle(color: KsColors.ink3))),
            data: (sessions) {
              if (sessions.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                  child: Text('Nothing scheduled today.',
                      style: TextStyle(color: KsColors.ink2)),
                );
              }
              final sorted = [...sessions]..sort((a, b) {
                  final sa = (a['startsAt'] ?? '').toString();
                  final sb = (b['startsAt'] ?? '').toString();
                  return sa.compareTo(sb);
                });
              return Column(
                children: [
                  for (var i = 0; i < sorted.length; i++)
                    _SessionRow(
                      s: sorted[i],
                      last: i == sorted.length - 1,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  final Map<String, dynamic> s;
  final bool last;
  const _SessionRow({required this.s, required this.last});

  @override
  Widget build(BuildContext context) {
    final tf = DateFormat('HH:mm');
    final start = DateTime.tryParse((s['startsAt'] ?? '').toString())?.toLocal();
    final code = (s['courseCode'] ?? '').toString();
    final hex = (s['courseAccentColour'] ?? '').toString();
    final locName = (s['locationName'] ?? '').toString();
    final instructor = (s['instructorName'] ?? '').toString();
    final active = (s['activeBookings'] as num?)?.toInt() ?? 0;
    final capacity = (s['capacity'] as num?)?.toInt() ?? 0;
    final accent = _courseAccent(code, hex);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: last
              ? BorderSide.none
              : BorderSide(color: KsColors.border.withValues(alpha: 0.7)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 4, height: 38,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(KsRadius.pill),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                          code.isEmpty ? '—' : '$code · $locName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w800,
                              fontSize: 13.5,
                              color: KsColors.ink)),
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  '${start == null ? '' : tf.format(start)} · '
                  '${instructor.split(' ').first} · $active/$capacity',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: KsColors.ink3, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _MiniAvatar(name: instructor),
        ],
      ),
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  final String name;
  const _MiniAvatar({required this.name});
  @override
  Widget build(BuildContext context) {
    final hue = _hueFromSeed(name);
    final bg = HSLColor.fromAHSL(1, hue, 0.42, 0.90).toColor();
    final fg = HSLColor.fromAHSL(1, hue, 0.55, 0.30).toColor();
    final initials = () {
      final parts =
          name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      if (parts.isEmpty) return '?';
      if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
      return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
          .toUpperCase();
    }();
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(initials,
          style: GoogleFonts.plusJakartaSans(
              color: fg, fontWeight: FontWeight.w800, fontSize: 10.5)),
    );
  }
}

double _hueFromSeed(String s) {
  if (s.isEmpty) return 277;
  var h = 0;
  for (final r in s.runes) {
    h = (h * 31 + r) & 0x7fffffff;
  }
  return (h % 360).toDouble();
}

Color _courseAccent(String code, [String hex = '']) {
  if (hex.isNotEmpty) {
    var s = hex.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6) {
      final n = int.tryParse(s, radix: 16);
      if (n != null) return Color(0xFF000000 | n);
    }
  }
  final c = code.toUpperCase();
  if (c.startsWith('CBT')) return KsColors.primary;
  if (c.startsWith('PRAC')) return KsColors.success;
  if (c.startsWith('TEST')) return KsColors.warning;
  return KsColors.primary;
}

// ===== Section label =====

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});
  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: GoogleFonts.plusJakartaSans(
            color: KsColors.ink3,
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6));
  }
}
