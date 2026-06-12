// Browse + book — the marquee student flow.
//
// Four steps in one screen, state-driven (not router-driven) so the back
// button feels native:
//
//   1. Pick a course type
//   2. Pick a slot   (filtered to that course, optionally a site)
//   3. Pick a bike   (recommended "Any" + each suitable named bike)
//   4. Review        (full summary + Confirm)
//
// Step 3 calls /sessions/{id}/suitable-bikes — the engine filters by
// category, transmission, readiness, and overlap so the picker only ever
// shows real options. Step 4 POSTs /bookings and routes to confirmation.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/student_top_actions.dart';

// Kept long-lived (no autoDispose) so tab switches read the cached list
// instead of hitting the API each time — that was the main source of the
// spinner-flash on every navigation. Pull-to-refresh / mutations
// explicitly invalidate when state changes.
final sessionsProvider = FutureProvider<List<SessionListing>>((ref) async {
  final api = ref.read(apiClientProvider);
  final now = DateTime.now();
  return api.listSessions(from: now, to: now.add(const Duration(days: 14)));
});

final courseTypesProvider = FutureProvider<List<CourseTypeLite>>((ref) async {
  return ref.read(apiClientProvider).listCourseTypes();
});

final suitableBikesProvider =
    FutureProvider.autoDispose.family<List<SuitableBike>, String>((ref, sessionId) async {
  return ref.read(apiClientProvider).suitableBikesForSession(sessionId);
});

/// Resolve a stable accent colour per course. Prefers the school-configured
/// `accent_colour` (hex string from the course-type editor), falling back
/// to a code-prefix mapping when nothing is set so the UI always has
/// something to render.
Color courseAccent(String code, [String hex = '']) {
  final parsed = _tryParseHexColour(hex);
  if (parsed != null) return parsed;
  final c = code.toUpperCase();
  if (c.startsWith('CBT')) return KsColors.primary;
  if (c.startsWith('PRAC')) return KsColors.success;
  if (c.startsWith('TEST')) return KsColors.warning;
  return KsColors.primary;
}

/// Parse `#RRGGBB` (or `RRGGBB`). Returns null on anything that doesn't
/// look like a 6-digit hex colour — callers should fall back.
Color? _tryParseHexColour(String hex) {
  var s = hex.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length != 6) return null;
  final n = int.tryParse(s, radix: 16);
  if (n == null) return null;
  return Color(0xFF000000 | n);
}

IconData courseIcon(String code) {
  final c = code.toUpperCase();
  if (c.startsWith('CBT')) return Icons.school_outlined;
  if (c.startsWith('PRAC')) return Icons.two_wheeler_rounded;
  if (c.startsWith('TEST')) return Icons.flag_outlined;
  return Icons.school_outlined;
}

class BrowseSessionsScreen extends ConsumerStatefulWidget {
  const BrowseSessionsScreen({super.key});

  @override
  ConsumerState<BrowseSessionsScreen> createState() => _BrowseSessionsScreenState();
}

class _BrowseSessionsScreenState extends ConsumerState<BrowseSessionsScreen> {
  int _step = 1;
  CourseTypeLite? _course;
  String _locationFilter = 'all';
  SessionListing? _session;
  String _bikeId = 'any';
  bool _submitting = false;
  String? _submitError;

  void _toStep(int s) => setState(() {
        _step = s;
        _submitError = null;
      });

  void _resetTo(int s) {
    setState(() {
      _step = s;
      _submitError = null;
      if (s <= 1) {
        _course = null;
        _locationFilter = 'all';
      }
      if (s <= 2) _session = null;
      if (s <= 3) _bikeId = 'any';
    });
  }

  Future<void> _confirm() async {
    if (_session == null) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final res = await api.book(
        sessionId: _session!.sessionId,
        bikeId: _bikeId == 'any' ? null : _bikeId,
      );
      if (!mounted) return;
      ref.read(lastBookingProvider.notifier).state = res;
      // Refresh anything the booking touched.
      ref.invalidate(sessionsProvider);
      context.go('/student/confirmed/${res.booking.id}');
    } on ApiException catch (e) {
      // The list lied: another student grabbed the slot or the engine ran
      // out of suitable bikes. Refresh so a back-tap shows honest capacity.
      if (e.code == 'capacity_full' || e.code == 'no_suitable_bike') {
        ref.invalidate(sessionsProvider);
      }
      setState(() {
        _submitError = _humanError(e);
        _submitting = false;
      });
    } catch (_) {
      setState(() {
        _submitError = 'Could not complete the booking. Try again.';
        _submitting = false;
      });
    }
  }

  String _humanError(ApiException e) {
    switch (e.code) {
      case 'already_booked':
        return 'You’ve already booked this session.';
      case 'capacity_full':
        return 'This session has just filled up.';
      case 'no_suitable_bike':
        return 'No suitable bike is available for this session.';
      case 'student_not_active':
        return 'Your account is awaiting approval. You can’t book yet.';
      case 'not_bookable':
        return 'This session is no longer bookable.';
      default:
        return e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPending =
        ref.watch(authControllerProvider).identity?.isPending ?? false;

    Widget body;
    switch (_step) {
      case 2:
        body = _StepSlots(
          course: _course!,
          locationFilter: _locationFilter,
          onLocationChange: (v) => setState(() => _locationFilter = v),
          onPick: (s) {
            setState(() {
              _session = s;
              _bikeId = 'any';
              _step = 3;
            });
          },
          onBack: () => _resetTo(1),
        );
        break;
      case 3:
        body = _StepBike(
          course: _course!,
          session: _session!,
          selectedBikeId: _bikeId,
          onPick: (v) => setState(() => _bikeId = v),
          onNext: () => _toStep(4),
          onBack: () => _resetTo(2),
        );
        break;
      case 4:
        body = _StepReview(
          course: _course!,
          session: _session!,
          selectedBikeId: _bikeId,
          pending: isPending,
          submitting: _submitting,
          submitError: _submitError,
          onConfirm: _confirm,
          onBack: () => _resetTo(3),
        );
        break;
      case 1:
      default:
        body = _StepCourse(
          pending: isPending,
          onPick: (c) {
            setState(() {
              _course = c;
              _session = null;
              _bikeId = 'any';
              _step = 2;
            });
          },
        );
    }

    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: _step == 1
          ? AppBar(
              title: Text('Book training',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, fontSize: 22)),
              automaticallyImplyLeading: false,
              actions: const [StudentTopActions()],
            )
          : null,
      body: SafeArea(child: body),
    );
  }
}

// ===== Step 1: course =====

class _StepCourse extends ConsumerWidget {
  final bool pending;
  final ValueChanged<CourseTypeLite> onPick;
  const _StepCourse({required this.pending, required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(courseTypesProvider);
    return async.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: KsColors.primary)),
      error: (e, _) => Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Couldn’t load courses.\n$e'))),
      data: (courses) {
        final visible = courses.where((c) => !c.nonTeaching).toList()
          ..addAll(courses.where((c) => c.nonTeaching));
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
          children: [
            const _StepBlurb(
                text:
                    'Pick a course to see honest, bike-aware availability.'),
            if (pending) ...[
              const SizedBox(height: 12),
              const _AwaitingApprovalBanner(),
            ],
            const SizedBox(height: 14),
            for (final c in visible) ...[
              _CourseCard(course: c, onTap: () => onPick(c)),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }
}

class _CourseCard extends StatelessWidget {
  final CourseTypeLite course;
  final VoidCallback onTap;
  const _CourseCard({required this.course, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = courseAccent(course.code, course.accentColour);
    final icon = courseIcon(course.code);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.lg),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: KsColors.border),
          boxShadow: KsShadows.sh1,
        ),
        child: Row(
          children: [
            Container(
              width: 46, height: 46,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(KsRadius.md),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: accent, size: 22),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(course.code,
                          style: GoogleFonts.spaceMono(
                              color: accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                      if (course.requiredBikeCategory.isNotEmpty) ...[
                        Text(
                            ' · cat ${course.requiredBikeCategory}',
                            style: const TextStyle(
                                color: KsColors.ink4, fontSize: 12)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(course.name,
                            style: GoogleFonts.plusJakartaSans(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                                color: KsColors.ink)),
                      ),
                      if (course.nonTeaching) ...[
                        const SizedBox(width: 8),
                        _MiniBadge(
                            label: 'Test day',
                            fg: KsColors.warning,
                            bg: KsColors.warningTint),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(_pricePounds(course.pricePence),
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
  }

  String _pricePounds(int pence) {
    final p = pence ~/ 100;
    final f = pence % 100;
    return f == 0 ? '£$p' : '£$p.${f.toString().padLeft(2, '0')}';
  }
}

// ===== Step 2: slots =====

class _StepSlots extends ConsumerWidget {
  final CourseTypeLite course;
  final String locationFilter;
  final ValueChanged<String> onLocationChange;
  final ValueChanged<SessionListing> onPick;
  final VoidCallback onBack;
  const _StepSlots({
    required this.course,
    required this.locationFilter,
    required this.onLocationChange,
    required this.onPick,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sessionsProvider);
    return async.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: KsColors.primary)),
      error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Couldn’t load sessions.\n$e')),
      data: (all) {
        final forCourse =
            all.where((s) => s.courseTypeId == course.id).toList();
        final locations = <String, String>{};
        for (final s in forCourse) {
          locations[s.locationId] = s.locationName;
        }
        final filtered = forCourse
            .where((s) =>
                locationFilter == 'all' || s.locationId == locationFilter)
            .toList();
        return RefreshIndicator(
          color: KsColors.primary,
          onRefresh: () async => ref.invalidate(sessionsProvider),
          child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          children: [
            _BackRow(
                onBack: onBack, code: course.code, name: course.name),
            const SizedBox(height: 16),
            if (locations.length > 1)
              _LocationStrip(
                items: [
                  const _LocChip(value: 'all', label: 'All sites'),
                  ...locations.entries.map((e) =>
                      _LocChip(value: e.key, label: e.value)),
                ],
                selected: locationFilter,
                onChange: onLocationChange,
              ),
            if (locations.length > 1) const SizedBox(height: 14),
            const _InfoBanner(
              icon: Icons.info_outline,
              text:
                  'Places shown are bike-aware — we only offer slots where a suitable bike is actually free.',
            ),
            const SizedBox(height: 12),
            if (filtered.isEmpty) const _Empty('No slots match — try a different site or wait for the next intake.'),
            for (final s in filtered) ...[
              _SlotCard(
                s: s,
                onTap: s.isFull ? null : () => onPick(s),
                onJoinWaitlist: s.isFull
                    ? () async {
                        try {
                          await ref.read(apiClientProvider)
                              .joinSessionWaitlist(s.sessionId);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: const Text(
                                  'Joined the waitlist — we\'ll book you in if a seat opens.'),
                              behavior: SnackBarBehavior.floating,
                            ));
                          }
                        } on ApiException catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(e.code == 'already_on_waitlist'
                                  ? 'You\'re already on this waitlist.'
                                  : 'Could not join: ${e.message}'),
                              backgroundColor: KsColors.danger,
                            ));
                          }
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 10),
            ],
          ],
          ),
        );
      },
    );
  }
}

class _SlotCard extends StatelessWidget {
  final SessionListing s;
  final VoidCallback? onTap;
  final VoidCallback? onJoinWaitlist;
  const _SlotCard({required this.s, required this.onTap, this.onJoinWaitlist});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('EEE d MMM');
    final tf = DateFormat('HH:mm');
    final full = s.isFull;
    return Opacity(
      opacity: full ? 0.55 : 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        child: Container(
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
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(df.format(s.startsAt),
                            style: GoogleFonts.plusJakartaSans(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: KsColors.ink)),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            const Icon(Icons.schedule,
                                size: 14, color: KsColors.ink3),
                            const SizedBox(width: 4),
                            Text(
                                '${tf.format(s.startsAt)}–${tf.format(s.endsAt)}',
                                style: const TextStyle(
                                    color: KsColors.ink3, fontSize: 13)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _CapacityBadge(s: s),
                ],
              ),
              const SizedBox(height: 11),
              Container(
                  height: 1,
                  color: KsColors.border.withValues(alpha: 0.6)),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.place_outlined,
                      size: 14, color: KsColors.ink3),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(s.locationName,
                        style: const TextStyle(
                            color: KsColors.ink2,
                            fontWeight: FontWeight.w600,
                            fontSize: 12.5)),
                  ),
                  const SizedBox(width: 14),
                  const Icon(Icons.person_outline,
                      size: 14, color: KsColors.ink3),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(s.instructorName.split(' ').first,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: KsColors.ink2,
                            fontWeight: FontWeight.w600,
                            fontSize: 12.5)),
                  ),
                  const Spacer(),
                  Icon(Icons.two_wheeler_rounded,
                      size: 14, color: KsColors.ink4),
                  const SizedBox(width: 4),
                  Text('${s.suitableFreeBikes} free',
                      style: const TextStyle(
                          color: KsColors.ink4,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              if (full && onJoinWaitlist != null) ...[
                const SizedBox(height: 10),
                Opacity(
                  opacity: 1, // override the parent's faded look for the CTA
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onJoinWaitlist,
                      icon: const Icon(Icons.notifications_active_outlined, size: 16),
                      label: const Text('Join waitlist'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: KsColors.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CapacityBadge extends StatelessWidget {
  final SessionListing s;
  const _CapacityBadge({required this.s});
  @override
  Widget build(BuildContext context) {
    if (s.isFull) {
      return _MiniBadge(label: 'Full', fg: KsColors.ink2, bg: KsColors.surface3);
    }
    final n = s.honestCapacity;
    if (n <= 1) {
      return _MiniBadge(
          label: '$n ${n == 1 ? 'place' : 'places'} left',
          fg: KsColors.warning,
          bg: KsColors.warningTint);
    }
    return _MiniBadge(
        label: '$n places left',
        fg: KsColors.success,
        bg: KsColors.successTint);
  }
}

// ===== Step 3: bike =====

class _StepBike extends ConsumerWidget {
  final CourseTypeLite course;
  final SessionListing session;
  final String selectedBikeId;
  final ValueChanged<String> onPick;
  final VoidCallback onNext;
  final VoidCallback onBack;
  const _StepBike({
    required this.course,
    required this.session,
    required this.selectedBikeId,
    required this.onPick,
    required this.onNext,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(suitableBikesProvider(session.sessionId));
    final df = DateFormat('EEE d MMM');
    final tf = DateFormat('HH:mm');
    final accent = courseAccent(course.code, course.accentColour);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            children: [
              _BackRow(
                  onBack: onBack,
                  code: course.code,
                  name:
                      '${df.format(session.startsAt)} · ${tf.format(session.startsAt)}'),
              const SizedBox(height: 16),
              _SectionLabel('Choose your bike'),
              const SizedBox(height: 10),
              _BikeOption(
                selected: selectedBikeId == 'any',
                onTap: () => onPick('any'),
                leading: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(KsRadius.md),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.auto_awesome, color: accent, size: 20),
                ),
                title: 'Any suitable bike',
                subtitle:
                    'We’ll auto-assign a free ${course.requiredBikeCategory.isEmpty ? 'matching' : course.requiredBikeCategory} bike',
                recommended: true,
              ),
              const SizedBox(height: 10),
              async.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                      child: CircularProgressIndicator(
                          color: KsColors.primary)),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('Couldn’t load bikes.\n$e',
                      style: const TextStyle(color: KsColors.ink3)),
                ),
                data: (bikes) {
                  if (bikes.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                          'No named bikes available right now — we’ll auto-assign.',
                          style:
                              TextStyle(color: KsColors.ink3, fontSize: 13)),
                    );
                  }
                  return Column(
                    children: [
                      for (final b in bikes) ...[
                        _BikeOption(
                          selected: selectedBikeId == b.bikeId,
                          onTap: () => onPick(b.bikeId),
                          leading: _BikeGlyph(category: b.category),
                          title: b.nickname.isEmpty
                              ? '${b.category} ${b.transmission}'
                              : b.nickname,
                          subtitle:
                              '${b.category} · ${b.engineCc}cc · ${b.transmission}',
                          trailingTag: b.isCrossSite
                              ? _MiniBadge(
                                  label: 'at ${b.currentLocationName}',
                                  fg: KsColors.warning,
                                  bg: KsColors.warningTint,
                                )
                              : null,
                          regLabel: b.registration,
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onNext,
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: const Text('Review booking'),
            ),
          ),
        ),
      ],
    );
  }
}

class _BikeOption extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget leading;
  final String title;
  final String subtitle;
  final String regLabel;
  final Widget? trailingTag;
  final bool recommended;
  const _BikeOption({
    required this.selected,
    required this.onTap,
    required this.leading,
    required this.title,
    required this.subtitle,
    this.regLabel = '',
    this.trailingTag,
    this.recommended = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.md),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.md),
          border: Border.all(
              color: selected ? KsColors.primary : KsColors.border,
              width: selected ? 2 : 1),
          boxShadow: selected ? KsShadows.sh2 : KsShadows.sh1,
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 7,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(title,
                          style: GoogleFonts.plusJakartaSans(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: KsColors.ink)),
                      if (recommended)
                        _MiniBadge(
                            label: 'Recommended',
                            fg: KsColors.primary,
                            bg: KsColors.primaryTint),
                      if (trailingTag != null) trailingTag!,
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(subtitle,
                            style: const TextStyle(
                                color: KsColors.ink3, fontSize: 12.5)),
                      ),
                      if (regLabel.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(regLabel,
                            style: GoogleFonts.spaceMono(
                                color: KsColors.ink4, fontSize: 11)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            _RadioDot(selected: selected),
          ],
        ),
      ),
    );
  }
}

class _BikeGlyph extends StatelessWidget {
  final String category;
  const _BikeGlyph({required this.category});
  @override
  Widget build(BuildContext context) {
    final color = switch (category) {
      'A' => KsColors.danger,
      'A2' => KsColors.warning,
      _ => KsColors.success,
    };
    return Container(
      width: 40, height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(KsRadius.md),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.two_wheeler_rounded, color: color, size: 22),
    );
  }
}

class _RadioDot extends StatelessWidget {
  final bool selected;
  const _RadioDot({required this.selected});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22, height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? KsColors.primary : Colors.transparent,
        border: selected
            ? null
            : Border.all(color: KsColors.border2, width: 2),
      ),
      child: selected
          ? const Icon(Icons.check, color: Colors.white, size: 14)
          : null,
    );
  }
}

// ===== Step 4: review =====

class _StepReview extends StatelessWidget {
  final CourseTypeLite course;
  final SessionListing session;
  final String selectedBikeId;
  final bool pending;
  final bool submitting;
  final String? submitError;
  final VoidCallback onConfirm;
  final VoidCallback onBack;
  const _StepReview({
    required this.course,
    required this.session,
    required this.selectedBikeId,
    required this.pending,
    required this.submitting,
    required this.submitError,
    required this.onConfirm,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('EEE d MMM yyyy');
    final tf = DateFormat('HH:mm');
    final accent = courseAccent(course.code, course.accentColour);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            children: [
              _BackRow(
                  onBack: onBack, code: course.code, name: 'Review'),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: KsColors.surface,
                  borderRadius: BorderRadius.circular(KsRadius.lg),
                  border: Border.all(color: KsColors.border),
                  boxShadow: KsShadows.sh1,
                ),
                clipBehavior: Clip.hardEdge,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      color: accent.withValues(alpha: 0.10),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(course.code,
                              style: GoogleFonts.spaceMono(
                                  fontSize: 11,
                                  color: accent,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(course.name,
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.3,
                                  color: KsColors.ink)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          _ReviewRow(
                              icon: Icons.event,
                              label: 'Date',
                              value: df.format(session.startsAt)),
                          _ReviewRow(
                              icon: Icons.schedule,
                              label: 'Time',
                              value:
                                  '${tf.format(session.startsAt)} – ${tf.format(session.endsAt)}'),
                          _ReviewRow(
                              icon: Icons.place_outlined,
                              label: 'Location',
                              value: session.locationName),
                          _ReviewRow(
                              icon: Icons.person_outline,
                              label: 'Instructor',
                              value: session.instructorName),
                          _ReviewRow(
                              icon: Icons.two_wheeler_rounded,
                              label: 'Bike',
                              value: selectedBikeId == 'any'
                                  ? 'Any suitable (auto-assigned)'
                                  : selectedBikeId,
                              last: true),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _InfoBanner(
                icon: Icons.info_outline,
                text:
                    'Free cancellation up to your school’s cut-off. Pay in person on the day — ${session.priceLabel}.',
              ),
              if (session.nonTeaching) ...[
                const SizedBox(height: 10),
                _InfoBanner(
                  icon: Icons.flag_outlined,
                  text:
                      'Heads-up: bring your CBT certificate and theory pass on the day. This reserves a bike + escort, not the test itself.',
                  tone: _BannerTone.warning,
                ),
              ],
              if (submitError != null) ...[
                const SizedBox(height: 10),
                _InfoBanner(
                  icon: Icons.error_outline,
                  text: submitError!,
                  tone: _BannerTone.danger,
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: pending || submitting ? null : onConfirm,
              icon: submitting
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.4),
                    )
                  : Icon(pending ? Icons.lock_outline : Icons.check, size: 18),
              label: Text(pending
                  ? 'Awaiting approval to book'
                  : 'Confirm booking · ${session.priceLabel}'),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReviewRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool last;
  const _ReviewRow({
    required this.icon,
    required this.label,
    required this.value,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(
                bottom: BorderSide(
                    color: KsColors.border.withValues(alpha: 0.6))),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: KsColors.ink4),
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: Text(label,
                style:
                    const TextStyle(color: KsColors.ink3, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: KsColors.ink)),
          ),
        ],
      ),
    );
  }
}

// ===== Shared bits =====

class _BackRow extends StatelessWidget {
  final VoidCallback onBack;
  final String code;
  final String name;
  const _BackRow(
      {required this.onBack, required this.code, required this.name});

  @override
  Widget build(BuildContext context) {
    final accent = courseAccent(code);
    return Row(
      children: [
        InkWell(
          onTap: onBack,
          borderRadius: BorderRadius.circular(KsRadius.sm),
          child: Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: KsColors.surface,
              borderRadius: BorderRadius.circular(KsRadius.sm),
              border: Border.all(color: KsColors.border),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.arrow_back_rounded,
                size: 19, color: KsColors.ink2),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(code,
                  style: GoogleFonts.spaceMono(
                      color: accent,
                      fontWeight: FontWeight.w700,
                      fontSize: 11)),
              Text(name,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      color: KsColors.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }
}

class _StepBlurb extends StatelessWidget {
  final String text;
  const _StepBlurb({required this.text});
  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            color: KsColors.ink3, fontSize: 14, height: 1.4));
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: GoogleFonts.plusJakartaSans(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: KsColors.ink2,
            letterSpacing: 0.4));
  }
}

class _MiniBadge extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  const _MiniBadge(
      {required this.label, required this.fg, required this.bg});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
      child: Text(label,
          style: GoogleFonts.plusJakartaSans(
              color: fg, fontWeight: FontWeight.w800, fontSize: 11)),
    );
  }
}

class _LocChip {
  final String value;
  final String label;
  const _LocChip({required this.value, required this.label});
}

class _LocationStrip extends StatelessWidget {
  final List<_LocChip> items;
  final String selected;
  final ValueChanged<String> onChange;
  const _LocationStrip(
      {required this.items, required this.selected, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: items.map((c) {
          final on = c.value == selected;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: () => onChange(c.value),
              borderRadius: BorderRadius.circular(KsRadius.pill),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(
                  color: on ? KsColors.primary : KsColors.surface,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                  border:
                      Border.all(color: on ? KsColors.primary : KsColors.border),
                ),
                child: Text(c.label,
                    style: GoogleFonts.plusJakartaSans(
                        color: on ? Colors.white : KsColors.ink2,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

enum _BannerTone { info, warning, danger }

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final _BannerTone tone;
  const _InfoBanner({
    required this.icon,
    required this.text,
    this.tone = _BannerTone.info,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      _BannerTone.warning => (KsColors.warningTint, KsColors.warning),
      _BannerTone.danger => (KsColors.dangerTint, KsColors.danger),
      _ => (KsColors.primaryTint, KsColors.primaryDeep),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KsRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(color: fg, fontSize: 12.5, height: 1.45)),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 18),
      child: Column(
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              color: KsColors.surface3,
              borderRadius: BorderRadius.circular(KsRadius.md),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.search,
                color: KsColors.ink4, size: 22),
          ),
          const SizedBox(height: 10),
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: KsColors.ink3, fontSize: 14)),
        ],
      ),
    );
  }
}

class _AwaitingApprovalBanner extends StatelessWidget {
  const _AwaitingApprovalBanner();
  @override
  Widget build(BuildContext context) {
    return _InfoBanner(
      icon: Icons.access_time_rounded,
      text:
          'Your account is awaiting approval — browse freely, but you can’t confirm a booking just yet.',
      tone: _BannerTone.warning,
    );
  }
}
