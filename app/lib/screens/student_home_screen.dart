// Student home — greeting, next-up hero, licence-journey row, progress
// snapshot, quick links. Pulls together data from the bookings, profile,
// tests, and progress endpoints already used by their respective tab
// screens — re-uses those providers so a refresh on any tab feeds the home.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/student_top_actions.dart';
import 'licence_screen.dart' show myProfileProvider, myTestsProvider;
import 'my_bookings_screen.dart' show myBookingsProvider;
import 'progress_screen.dart' show myProgressProvider;

class StudentHomeScreen extends ConsumerWidget {
  const StudentHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final id = auth.identity;
    final firstName = (id?.name.split(' ').first ?? 'there');
    final greeting = _greetingFor(DateTime.now());

    return Scaffold(
      backgroundColor: KsColors.bg,
      body: SafeArea(
        child: RefreshIndicator(
          color: KsColors.primary,
          onRefresh: () async {
            ref.invalidate(myBookingsProvider('upcoming'));
            ref.invalidate(myProfileProvider);
            ref.invalidate(myTestsProvider);
            ref.invalidate(myProgressProvider);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            children: [
              _GreetingBar(
                greeting: greeting,
                firstName: firstName,
              ),
              const SizedBox(height: 12),
              if (id?.isPending ?? false) ...[
                const _PendingBanner(),
                const SizedBox(height: 12),
              ],
              const _NextUpHero(),
              const SizedBox(height: 22),
              const _SectionLabel('Your licence journey'),
              const SizedBox(height: 10),
              const _LicenceJourneyRow(),
              const SizedBox(height: 10),
              const _PracticalTestCard(),
              const SizedBox(height: 22),
              _SectionLabel(
                'Practical training progress',
                action: TextButton(
                  onPressed: () => context.go('/student/progress'),
                  style: TextButton.styleFrom(
                    foregroundColor: KsColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text('View all',
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              ),
              const SizedBox(height: 10),
              const _ProgressSnapshotCard(),
              const SizedBox(height: 14),
              _LinkRow(
                icon: Icons.badge_outlined,
                label: 'Licence & documents',
                onTap: () => context.go('/student/licence'),
              ),
              const SizedBox(height: 10),
              _LinkRow(
                icon: Icons.qr_code_2_rounded,
                label: 'Invite a friend',
                onTap: () => _showInviteSheet(context, id),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _greetingFor(DateTime t) {
  final h = t.hour;
  if (h < 12) return 'Good morning,';
  if (h < 18) return 'Good afternoon,';
  return 'Good evening,';
}

void _showInviteSheet(BuildContext context, Identity? id) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
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
            Text('Invite a friend',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text(
              'Share your school’s booking link — they scan, pick a course, '
              'and they’re in.',
              style: TextStyle(color: KsColors.ink3),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: KsColors.surface2,
                borderRadius: BorderRadius.circular(KsRadius.md),
                border: Border.all(color: KsColors.border),
              ),
              child: const Center(
                child: Icon(Icons.qr_code_2_rounded,
                    size: 100, color: KsColors.ink2),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Sharing is coming soon — your QR will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: KsColors.ink3, fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
}

// ----- Greeting bar -----

class _GreetingBar extends StatelessWidget {
  final String greeting;
  final String firstName;
  const _GreetingBar({required this.greeting, required this.firstName});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(greeting,
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: KsColors.ink3)),
                const SizedBox(height: 2),
                Text('$firstName 👋',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                        color: KsColors.ink)),
              ],
            ),
          ),
          const StudentTopActions(trailingPadding: 0),
        ],
      ),
    );
  }
}

// ----- Pending banner -----

class _PendingBanner extends StatelessWidget {
  const _PendingBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: KsColors.warningTint,
        borderRadius: BorderRadius.circular(KsRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: KsColors.warning,
              borderRadius: BorderRadius.circular(KsRadius.sm),
            ),
            child: const Icon(Icons.access_time_rounded,
                color: Colors.white, size: 20),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Awaiting approval',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 14.5, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                const Text(
                  'Your school is reviewing your sign-up. You can browse, '
                  'and we’ll text you once you’re cleared to book.',
                  style: TextStyle(color: KsColors.ink2, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ----- Next-up hero -----

class _NextUpHero extends ConsumerWidget {
  const _NextUpHero();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myBookingsProvider('upcoming'));
    return async.when(
      loading: () => const _HeroSkeleton(),
      error: (_, __) => const _NoUpcomingHero(),
      data: (bookings) {
        final next = bookings.where((b) => b.isActive).fold<MyBooking?>(
            null,
            (best, b) => best == null || b.startsAt.isBefore(best.startsAt)
                ? b
                : best);
        if (next == null) return const _NoUpcomingHero();
        return _UpcomingHero(b: next);
      },
    );
  }
}

class _UpcomingHero extends StatelessWidget {
  final MyBooking b;
  const _UpcomingHero({required this.b});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('EEE d MMM');
    final tf = DateFormat('HH:mm');
    return InkWell(
      onTap: () => context.go('/student/bookings'),
      borderRadius: BorderRadius.circular(KsRadius.xl),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [KsColors.primaryDeep, KsColors.primary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(KsRadius.xl),
          boxShadow: KsShadows.shPrimary,
        ),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // Decorative bg circle
            Positioned(
              right: -28, top: -28,
              child: Container(
                width: 130, height: 130,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Positioned(
              right: 14, bottom: 8,
              child: Icon(Icons.two_wheeler_rounded,
                  size: 60, color: Colors.white.withValues(alpha: 0.22)),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bolt_rounded,
                        size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(
                      'NEXT UP · ${df.format(b.startsAt).toUpperCase()}',
                      style: GoogleFonts.plusJakartaSans(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 11.5,
                          letterSpacing: 1.2),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(b.courseName,
                    style: GoogleFonts.plusJakartaSans(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                        height: 1.15)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    _heroChip(Icons.schedule, tf.format(b.startsAt)),
                    _heroChip(Icons.place_outlined, b.locationName),
                    _heroChip(Icons.person_outline,
                        b.instructorName.split(' ').first),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(KsRadius.md),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.two_wheeler_rounded,
                          size: 18, color: Colors.white),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          b.bikeNickname.isEmpty
                              ? 'Bike auto-assigned'
                              : b.bikeNickname,
                          style: GoogleFonts.plusJakartaSans(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5),
                        ),
                      ),
                      if (b.needsReassignment)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius:
                                BorderRadius.circular(KsRadius.pill),
                          ),
                          child: Text('Needs reassign',
                              style: GoogleFonts.plusJakartaSans(
                                  color: KsColors.warning,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 10.5)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroChip(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.95)),
        const SizedBox(width: 5),
        Text(label,
            style: GoogleFonts.plusJakartaSans(
                color: Colors.white.withValues(alpha: 0.95),
                fontWeight: FontWeight.w600,
                fontSize: 13)),
      ],
    );
  }
}

class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 170,
      decoration: BoxDecoration(
        color: KsColors.surface2,
        borderRadius: BorderRadius.circular(KsRadius.xl),
      ),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22, height: 22,
        child: CircularProgressIndicator(color: KsColors.primary, strokeWidth: 2.5),
      ),
    );
  }
}

class _NoUpcomingHero extends StatelessWidget {
  const _NoUpcomingHero();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.xl),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      child: Column(
        children: [
          Text('No upcoming sessions',
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  fontSize: 16)),
          const SizedBox(height: 4),
          const Text('Browse and book to get started.',
              style: TextStyle(color: KsColors.ink3, fontSize: 13)),
          const SizedBox(height: 14),
          ElevatedButton.icon(
            onPressed: () => context.go('/student/browse'),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Book training'),
          ),
        ],
      ),
    );
  }
}

// ----- Licence journey row -----

class _LicenceJourneyRow extends ConsumerWidget {
  const _LicenceJourneyRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myProfileProvider);
    return async.when(
      loading: () => const SizedBox(height: 86),
      error: (_, __) => const SizedBox.shrink(),
      data: (p) {
        final cbtValue = _cbtValueLabel(p);
        final theoryValue = p.theoryPassed ? 'Passed' : 'Not yet';
        return Row(
          children: [
            Expanded(
              child: _StatTile(
                icon: Icons.verified_user_outlined,
                fg: KsColors.success,
                bg: KsColors.successTint,
                label: 'CBT',
                value: cbtValue,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatTile(
                icon: Icons.menu_book_outlined,
                fg: KsColors.primary,
                bg: KsColors.primaryTint,
                label: 'Theory',
                value: theoryValue,
              ),
            ),
          ],
        );
      },
    );
  }

  String _cbtValueLabel(StudentProfile p) {
    if (!p.cbtHeld) return 'Not held';
    if (p.cbtExpiresOn.isEmpty) return 'Held';
    try {
      final d = DateFormat('yyyy-MM-dd').parseStrict(p.cbtExpiresOn);
      return 'to ${DateFormat('d MMM').format(d)}';
    } catch (_) {
      return 'Held';
    }
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color fg, bg;
  final String label, value;
  const _StatTile({
    required this.icon,
    required this.fg,
    required this.bg,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
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
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(KsRadius.sm),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: fg, size: 18),
          ),
          const SizedBox(height: 9),
          Text(label,
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 1),
          Text(value,
              style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
        ],
      ),
    );
  }
}

// ----- Practical test booked card -----

class _PracticalTestCard extends ConsumerWidget {
  const _PracticalTestCard();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myTestsProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (tests) {
        final t = tests
            .where((t) =>
                t.outcome == 'booked' &&
                t.testType == 'practical' &&
                t.scheduledAt != null &&
                t.scheduledAt!.isAfter(DateTime.now()))
            .fold<ExternalTest?>(
                null,
                (best, t) =>
                    best == null || t.scheduledAt!.isBefore(best.scheduledAt!)
                        ? t
                        : best);
        if (t == null) return const SizedBox.shrink();
        final days = t.scheduledAt!.difference(DateTime.now()).inDays;
        final df = DateFormat('d MMM');
        final tf = DateFormat('HH:mm');
        return Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: KsColors.surface,
            borderRadius: BorderRadius.circular(KsRadius.lg),
            border: Border.all(color: KsColors.warning.withValues(alpha: 0.3)),
            boxShadow: KsShadows.sh1,
          ),
          child: Row(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: KsColors.warningTint,
                  borderRadius: BorderRadius.circular(KsRadius.sm),
                ),
                child: const Icon(Icons.flag_outlined,
                    color: KsColors.warning, size: 22),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Practical test booked',
                        style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                      '${df.format(t.scheduledAt!)} · ${tf.format(t.scheduledAt!)}'
                      '${t.reference.isEmpty ? '' : ' · ${t.reference}'}',
                      style: const TextStyle(color: KsColors.ink3, fontSize: 12.5),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  Text('$days',
                      style: GoogleFonts.plusJakartaSans(
                          color: KsColors.warning,
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                          height: 1)),
                  Text(days == 1 ? 'DAY' : 'DAYS',
                      style: GoogleFonts.plusJakartaSans(
                          color: KsColors.ink4,
                          fontWeight: FontWeight.w700,
                          fontSize: 10.5)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ----- Progress snapshot -----

class _ProgressSnapshotCard extends ConsumerWidget {
  const _ProgressSnapshotCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myProgressProvider);
    return async.when(
      loading: () => const SizedBox(height: 80),
      error: (_, __) => const SizedBox.shrink(),
      data: (courses) {
        // Pick the in-progress course with the most signal — most signed-off,
        // tie-break on most total. Skip empty.
        final inProgress = courses.where((c) => c.totalCompetencies > 0).toList()
          ..sort((a, b) {
            final pa = a.competentCount / a.totalCompetencies;
            final pb = b.competentCount / b.totalCompetencies;
            if (pa == pb) return b.totalCompetencies.compareTo(a.totalCompetencies);
            return pb.compareTo(pa);
          });
        if (inProgress.isEmpty) {
          return InkWell(
            onTap: () => context.go('/student/progress'),
            borderRadius: BorderRadius.circular(KsRadius.lg),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: KsColors.surface,
                borderRadius: BorderRadius.circular(KsRadius.lg),
                border: Border.all(color: KsColors.border),
                boxShadow: KsShadows.sh1,
              ),
              child: Row(
                children: const [
                  Icon(Icons.flag_circle_outlined,
                      color: KsColors.ink3, size: 28),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Once your instructor signs off competencies, they appear here.',
                      style: TextStyle(color: KsColors.ink2, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final c = inProgress.first;
        final remaining = c.totalCompetencies - c.competentCount;
        final hint = remaining == 0
            ? 'All signed off — nice riding.'
            : '$remaining to go — keep it up!';
        return InkWell(
          onTap: () => context.go('/student/progress'),
          borderRadius: BorderRadius.circular(KsRadius.lg),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: KsColors.surface,
              borderRadius: BorderRadius.circular(KsRadius.lg),
              border: Border.all(color: KsColors.border),
              boxShadow: KsShadows.sh1,
            ),
            child: Row(
              children: [
                _ProgressRing(
                  done: c.competentCount,
                  total: c.totalCompetencies,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${c.competentCount} of ${c.totalCompetencies} signed off',
                        style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800, fontSize: 15),
                      ),
                      const SizedBox(height: 3),
                      Text(hint,
                          style: const TextStyle(
                              color: KsColors.ink3, fontSize: 13)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: KsColors.ink4),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ProgressRing extends StatelessWidget {
  final int done, total;
  const _ProgressRing({required this.done, required this.total});
  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? 0.0 : done / total;
    return SizedBox(
      width: 64, height: 64,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 64, height: 64,
            child: CircularProgressIndicator(
              value: 1,
              strokeWidth: 6,
              valueColor: const AlwaysStoppedAnimation(KsColors.surface3),
            ),
          ),
          SizedBox(
            width: 64, height: 64,
            child: CircularProgressIndicator(
              value: pct,
              strokeWidth: 6,
              valueColor: const AlwaysStoppedAnimation(KsColors.success),
              strokeCap: StrokeCap.round,
            ),
          ),
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              style: GoogleFonts.plusJakartaSans(
                  color: KsColors.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 15),
              children: [
                TextSpan(text: '$done'),
                TextSpan(
                  text: '/$total',
                  style: const TextStyle(color: KsColors.ink4, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ----- Section label -----

class _SectionLabel extends StatelessWidget {
  final String text;
  final Widget? action;
  const _SectionLabel(this.text, {this.action});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: KsColors.ink2,
                letterSpacing: 0.4),
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}

// ----- Link row -----

class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _LinkRow({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.md),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.md),
          border: Border.all(color: KsColors.border),
          boxShadow: KsShadows.sh1,
        ),
        child: Row(
          children: [
            Icon(icon, color: KsColors.primary, size: 19),
            const SizedBox(width: 11),
            Expanded(
              child: Text(label,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: KsColors.ink)),
            ),
            const Icon(Icons.chevron_right_rounded, color: KsColors.ink4),
          ],
        ),
      ),
    );
  }
}
