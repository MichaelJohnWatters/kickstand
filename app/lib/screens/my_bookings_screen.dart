// My Bookings — Upcoming + Past, segmented with counts. Cards have a
// course-coloured left stripe and the course code in mono. For active
// bookings, Reschedule + Cancel sit inline on the card (no bottom sheet).
//
// Cancel runs in-place with a confirmation dialog so the user can change
// their mind. Reschedule routes back to Browse — the 4-step flow takes
// over from there, the cancel half runs server-side as part of POST
// /bookings/{id}/reschedule (TODO: lift reschedule into Browse properly).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/student_top_actions.dart';
import 'browse_sessions_screen.dart' show courseAccent, sessionsProvider;

// Long-lived so the Home hero, My Bookings tab, and any other consumer
// share a single cached list. Mutations (book / cancel / reschedule)
// invalidate it explicitly.
final myBookingsProvider =
    FutureProvider.family<List<MyBooking>, String>((ref, when) async {
  final api = ref.read(apiClientProvider);
  return api.listMyBookings(when: when);
});

class MyBookingsScreen extends ConsumerStatefulWidget {
  const MyBookingsScreen({super.key});
  @override
  ConsumerState<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends ConsumerState<MyBookingsScreen> {
  String _segment = 'upcoming';

  @override
  Widget build(BuildContext context) {
    final upcomingAsync = ref.watch(myBookingsProvider('upcoming'));
    final pastAsync = ref.watch(myBookingsProvider('past'));
    final upcomingCount =
        upcomingAsync.maybeWhen(data: (l) => l.length, orElse: () => 0);
    final pastCount =
        pastAsync.maybeWhen(data: (l) => l.length, orElse: () => 0);

    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: Text('My bookings',
            style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w800, fontSize: 22)),
        actions: const [StudentTopActions()],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
          child: Column(
            children: [
              _SegmentedControl(
                value: _segment,
                onChange: (v) => setState(() => _segment = v),
                upcomingCount: upcomingCount,
                pastCount: pastCount,
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _BookingsList(
                  when: _segment,
                  isUpcoming: _segment == 'upcoming',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentedControl extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChange;
  final int upcomingCount;
  final int pastCount;
  const _SegmentedControl({
    required this.value,
    required this.onChange,
    required this.upcomingCount,
    required this.pastCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: KsColors.surface2,
        borderRadius: BorderRadius.circular(KsRadius.pill),
        border: Border.all(color: KsColors.border),
      ),
      child: Row(
        children: [
          _segBtn(
              'upcoming', 'Upcoming${upcomingCount > 0 ? ' ($upcomingCount)' : ''}'),
          _segBtn('past', 'Past${pastCount > 0 ? ' ($pastCount)' : ''}'),
        ],
      ),
    );
  }

  Expanded _segBtn(String v, String label) {
    final on = value == v;
    return Expanded(
      child: InkWell(
        onTap: () => onChange(v),
        borderRadius: BorderRadius.circular(KsRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: on ? KsColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(KsRadius.pill),
            boxShadow: on ? KsShadows.sh1 : null,
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: GoogleFonts.plusJakartaSans(
                  color: on ? KsColors.ink : KsColors.ink3,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5)),
        ),
      ),
    );
  }
}

class _BookingsList extends ConsumerWidget {
  final String when;
  final bool isUpcoming;
  const _BookingsList({required this.when, required this.isUpcoming});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myBookingsProvider(when));
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async {
        ref.invalidate(myBookingsProvider('upcoming'));
        ref.invalidate(myBookingsProvider('past'));
      },
      child: async.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: KsColors.primary)),
        error: (e, _) => ListView(children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Couldn’t load bookings.\n$e',
                style: const TextStyle(color: KsColors.ink3)),
          ),
        ]),
        data: (bookings) {
          if (bookings.isEmpty) {
            return ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 60, 24, 24),
                  child: Column(
                    children: [
                      Container(
                        width: 56, height: 56,
                        decoration: BoxDecoration(
                          color: KsColors.surface3,
                          borderRadius: BorderRadius.circular(KsRadius.md),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          isUpcoming
                              ? Icons.event_available_outlined
                              : Icons.history,
                          color: KsColors.ink4, size: 28,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        isUpcoming
                            ? 'Nothing booked yet.'
                            : 'No past sessions.',
                        style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: KsColors.ink2),
                      ),
                      const SizedBox(height: 6),
                      if (isUpcoming) ...[
                        const Text(
                          'Browse and book to get started.',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: KsColors.ink3, fontSize: 13),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => context.go('/student/browse'),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Book training'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(top: 4, bottom: 24),
            itemCount: bookings.length + (isUpcoming ? 1 : 0),
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (ctx, i) {
              if (i == bookings.length) {
                // Upcoming-only footer CTA — "soft" variant from the design
                // (primary-tint background, primary text). Use SizedBox to
                // fill width — `minimumSize: Size(double.infinity, 0)` on
                // the button style was tripping unbounded-width assertions
                // and cascading into "Unexpected null value" errors that
                // poisoned later renders.
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => context.go('/student/browse'),
                      style: ElevatedButton.styleFrom(
                        foregroundColor: KsColors.primaryDeep,
                        backgroundColor: KsColors.primaryTint,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Book another session'),
                    ),
                  ),
                );
              }
              return _BookingCard(b: bookings[i]);
            },
          );
        },
      ),
    );
  }
}

class _BookingCard extends ConsumerStatefulWidget {
  final MyBooking b;
  const _BookingCard({required this.b});
  @override
  ConsumerState<_BookingCard> createState() => _BookingCardState();
}

class _BookingCardState extends ConsumerState<_BookingCard> {
  bool _cancelling = false;
  String? _error;

  Future<void> _confirmCancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KsRadius.lg)),
        title: const Text('Cancel this booking?'),
        content: Text(
            'Your bike and place will be released. Late cancellations may incur a charge per your school’s policy.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Keep it')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: KsColors.danger),
            child: const Text('Cancel booking'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _cancelling = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      await api.cancelBooking(widget.b.bookingId,
          reason: 'Cancelled by student');
      if (!mounted) return;
      ref.invalidate(myBookingsProvider('upcoming'));
      ref.invalidate(myBookingsProvider('past'));
      ref.invalidate(sessionsProvider);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _cancelling = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not cancel. Try again.';
        _cancelling = false;
      });
    }
  }

  void _reschedule() => context.go('/student/browse');

  @override
  Widget build(BuildContext context) {
    final b = widget.b;
    final accent = courseAccent(b.courseCode, b.courseAccentColour);
    final df = DateFormat('EEE d MMM');
    final tf = DateFormat('HH:mm');
    final cancelled = b.isCancelled;
    final completed = b.isCompleted;
    final noShow = b.isNoShow;

    return Opacity(
      opacity: cancelled ? 0.65 : 1,
      child: Container(
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: KsColors.border),
          boxShadow: KsShadows.sh1,
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            // Header row with coloured stripe down the left.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: 5, color: accent),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(b.courseCode,
                                        style: GoogleFonts.spaceMono(
                                            color: accent,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 11)),
                                    const SizedBox(height: 1),
                                    Text(b.courseName,
                                        style: GoogleFonts.plusJakartaSans(
                                            fontSize: 16.5,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.2,
                                            color: KsColors.ink)),
                                  ],
                                ),
                              ),
                              _StatusChip(b: b),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 14,
                            runSpacing: 6,
                            children: [
                              _meta(Icons.event, df.format(b.startsAt)),
                              _meta(Icons.schedule,
                                  '${tf.format(b.startsAt)}–${tf.format(b.endsAt)}'),
                              _meta(Icons.place_outlined, b.locationName),
                              _meta(
                                  Icons.two_wheeler_rounded,
                                  b.bikeNickname.isEmpty
                                      ? 'Auto bike'
                                      : b.bikeNickname),
                            ],
                          ),
                          if (cancelled &&
                              b.cancellationReason.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text('Reason: ${b.cancellationReason}',
                                style: const TextStyle(
                                    color: KsColors.ink3,
                                    fontSize: 12,
                                    fontStyle: FontStyle.italic)),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 8),
                            Text(_error!,
                                style: const TextStyle(
                                    color: KsColors.danger, fontSize: 12.5)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (b.isActive && !completed && !cancelled && !noShow)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _cancelling ? null : _reschedule,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: KsColors.ink,
                          side: const BorderSide(color: KsColors.border2),
                          minimumSize: const Size(0, 40),
                        ),
                        icon: const Icon(Icons.swap_horiz, size: 18),
                        label: const Text('Reschedule'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _cancelling ? null : _confirmCancel,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: KsColors.danger,
                          side: BorderSide(
                              color: KsColors.danger.withValues(alpha: 0.6)),
                          backgroundColor:
                              KsColors.danger.withValues(alpha: 0.06),
                          minimumSize: const Size(0, 40),
                        ),
                        icon: _cancelling
                            ? const SizedBox(
                                width: 14, height: 14,
                                child: CircularProgressIndicator(
                                    color: KsColors.danger,
                                    strokeWidth: 2.2),
                              )
                            : const Icon(Icons.close_rounded, size: 18),
                        label: const Text('Cancel'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: KsColors.ink3),
          const SizedBox(width: 5),
          Text(text,
              style: GoogleFonts.plusJakartaSans(
                  color: KsColors.ink2,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
        ],
      );
}

class _StatusChip extends StatelessWidget {
  final MyBooking b;
  const _StatusChip({required this.b});
  @override
  Widget build(BuildContext context) {
    late Color fg, bg;
    late String label;
    switch (b.status) {
      case 'booked':
        fg = KsColors.primary;
        bg = KsColors.primaryTint;
        label = 'Confirmed';
        break;
      case 'needs_reassignment':
        fg = KsColors.warning;
        bg = KsColors.warningTint;
        label = 'Needs reassign';
        break;
      case 'completed':
        fg = KsColors.success;
        bg = KsColors.successTint;
        label = 'Completed';
        break;
      case 'no_show':
        fg = KsColors.danger;
        bg = KsColors.dangerTint;
        label = 'No-show';
        break;
      case 'cancelled':
        fg = KsColors.ink3;
        bg = KsColors.surface3;
        label = 'Cancelled';
        break;
      default:
        fg = KsColors.ink3;
        bg = KsColors.surface3;
        label = b.status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text(label,
          style: GoogleFonts.plusJakartaSans(
              color: fg, fontWeight: FontWeight.w800, fontSize: 11.5)),
    );
  }
}
