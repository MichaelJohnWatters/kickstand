// Admin Disruptions — list of open bike-down events with per-affected-booking
// resolution UI (Swap to suggested bike / Cancel with approval).
//
// Per plan §6, the goal is to surface the choice cleanly: swap is the happy
// path (auto-suggested suitable bike), cancel-with-approval is blameless.
//
// Layout mirrors design_handoff_kickstand/app/admin-fleet.jsx DisruptionScreen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

class AdminDisruptionsScreen extends ConsumerWidget {
  const AdminDisruptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(openDisruptionsProvider);
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(openDisruptionsProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Resolve disruptions',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  letterSpacing: -0.6)),
          const SizedBox(height: 4),
          const Text(
            'Reassign affected bookings or cancel with manager approval.',
            style: TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 18),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => KsEmptyState.error(message: e.toString()),
            data: (rows) {
              if (rows.isEmpty) return const _EmptyState();
              // Count pending affected bookings whose session has
              // already ended — these need cleanup so the seat unblocks
              // and the audit log reflects what really happened.
              final now = DateTime.now();
              int pastPending = 0;
              for (final d in rows) {
                for (final b in ((d['affectedBookings'] as List?) ?? const [])
                    .cast<Map<String, dynamic>>()) {
                  if ((b['resolution'] ?? '').toString() != 'pending') continue;
                  final ends = DateTime.tryParse(b['sessionEndsAt'] ?? '')?.toLocal();
                  if (ends != null && ends.isBefore(now)) pastPending++;
                }
              }
              return Column(
                children: [
                  if (pastPending > 0) ...[
                    _PastPendingBanner(count: pastPending),
                    const SizedBox(height: 20),
                  ],
                  for (final d in rows) ...[
                    _DisruptionBlock(disruption: d),
                    const SizedBox(height: 28),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Header banner shown when there are unresolved affected bookings on
/// sessions that have already ended. Offers a single "Dismiss past"
/// button that bulk applies cancel-with-approval — the seat unblocks,
/// the audit log captures the cleanup, and the disruptions board stops
/// growing zombie rows. Manual, not automatic, because cancel has
/// notification side effects.
class _PastPendingBanner extends ConsumerStatefulWidget {
  final int count;
  const _PastPendingBanner({required this.count});

  @override
  ConsumerState<_PastPendingBanner> createState() => _PastPendingBannerState();
}

class _PastPendingBannerState extends ConsumerState<_PastPendingBanner> {
  bool _saving = false;

  Future<void> _dismissAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Dismiss ${widget.count} past-due disruption${widget.count == 1 ? '' : 's'}?'),
        content: const Text(
            'Each row closes out as "dismissed" in the audit log. Bookings and any charges on them stay as-is — students may have attended on a workaround bike, and we don’t auto-refund. Use this when the session has already passed and the row was never resolved.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: KsColors.danger,
                foregroundColor: Colors.white),
            child: const Text('Dismiss all'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _saving = true);
    try {
      final n = await ref.read(apiClientProvider).dismissPastDisruptions();
      ref.invalidate(openDisruptionsProvider);
      messenger?.showSnackBar(SnackBar(
        content:
            Text('Dismissed $n past-due disruption${n == 1 ? '' : 's'}'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(
        content: Text('Couldn’t dismiss: $e'),
        backgroundColor: KsColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: KsColors.warningTint,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.warning.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(children: [
        const Icon(Icons.history_toggle_off,
            color: KsColors.warning, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.count} booking${widget.count == 1 ? '' : 's'} stuck past session start',
                style: GoogleFonts.plusJakartaSans(
                    color: KsColors.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 14),
              ),
              const SizedBox(height: 2),
              const Text(
                'These bookings sat in needs-reassignment until after the session ended. Tidy them so the seats free up.',
                style: TextStyle(color: KsColors.ink2, fontSize: 12.5),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: _saving ? null : _dismissAll,
          icon: _saving
              ? const SizedBox.shrink()
              : const Icon(Icons.clear_all, size: 16),
          label: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5))
              : const Text('Dismiss past'),
          style: ElevatedButton.styleFrom(
            backgroundColor: KsColors.warning,
            foregroundColor: Colors.white,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
        ),
      ]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(
        children: [
          const Icon(Icons.check_circle_outline, size: 48, color: KsColors.success),
          const SizedBox(height: 12),
          Text('No open disruptions',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 16, fontWeight: FontWeight.w700, color: KsColors.ink)),
          const SizedBox(height: 4),
          const Text('Everything’s running.', style: TextStyle(color: KsColors.ink2)),
        ],
      ),
    );
  }
}

/// One disruption — the danger-tinted hero banner plus its affected-booking cards.
class _DisruptionBlock extends StatelessWidget {
  final Map<String, dynamic> disruption;
  const _DisruptionBlock({required this.disruption});

  @override
  Widget build(BuildContext context) {
    final affected = ((disruption['affectedBookings'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final resolved = affected
        .where((a) => _isResolved((a['resolution'] ?? '').toString()))
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HeroBanner(
          disruption: disruption,
          resolved: resolved,
          total: affected.length,
        ),
        if (affected.isNotEmpty) ...[
          const SizedBox(height: 18),
          const _SectionLabel('Affected bookings'),
          for (final b in affected)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _AffectedBookingCard(
                disruptionId: (disruption['disruptionId'] ?? '').toString(),
                booking: b,
              ),
            ),
        ] else ...[
          const SizedBox(height: 12),
          const Text(
            'No bookings were on this bike. Restore from the Fleet screen when it’s back in service.',
            style: TextStyle(color: KsColors.ink2, fontSize: 13),
          ),
        ],
      ],
    );
  }

  static bool _isResolved(String r) =>
      r == 'swapped' || r == 'cancelled' || r == 'cancel_with_approval';
}

class _HeroBanner extends StatelessWidget {
  final Map<String, dynamic> disruption;
  final int resolved;
  final int total;
  const _HeroBanner({
    required this.disruption,
    required this.resolved,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final bikeNickname = (disruption['bikeNickname'] ?? '').toString();
    final bikeReg = (disruption['bikeRegistration'] ?? '').toString();
    final reason = (disruption['reason'] ?? '').toString();
    final reportedBy = (disruption['reportedByName'] ?? '').toString();
    final locationName = (disruption['locationName'] ?? '').toString();
    final startedAt = DateTime.tryParse(disruption['startedAt'] ?? '')?.toLocal();

    final metaParts = <String>[
      if (reason.isNotEmpty) reason,
      if (reportedBy.isNotEmpty) 'reported by $reportedBy',
      if (startedAt != null) _humanWhen(startedAt),
      if (locationName.isNotEmpty) locationName,
    ];

    return Container(
      decoration: BoxDecoration(
        color: KsColors.dangerTint,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.danger),
      ),
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: KsColors.danger,
              borderRadius: BorderRadius.circular(KsRadius.md),
            ),
            child: const Icon(Icons.report_problem_rounded,
                color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      bikeNickname.isEmpty ? 'Bike' : '$bikeNickname is down',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: KsColors.ink),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (bikeReg.isNotEmpty) ...[
                    const SizedBox(width: 9),
                    Text(bikeReg,
                        style: GoogleFonts.spaceMono(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: KsColors.danger)),
                  ],
                  const SizedBox(width: 9),
                  const _Badge(label: 'Offline', tone: _Tone.danger),
                ]),
                if (metaParts.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(metaParts.join(' · '),
                      style: const TextStyle(color: KsColors.ink2, fontSize: 13)),
                ],
              ],
            ),
          ),
          if (total > 0) ...[
            const SizedBox(width: 12),
            Column(
              children: [
                Text('$resolved/$total',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: KsColors.danger,
                        height: 1)),
                const SizedBox(height: 2),
                Text('RESOLVED',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: KsColors.ink3,
                        letterSpacing: 0.4)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _humanWhen(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(that).inDays;
    final t = DateFormat('HH:mm').format(dt);
    if (diff == 0) return 'Today $t';
    if (diff == 1) return 'Yesterday $t';
    return '${DateFormat('d MMM').format(dt)} $t';
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 10),
      child: Text(
        label.toUpperCase(),
        style: GoogleFonts.plusJakartaSans(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: KsColors.ink3,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _AffectedBookingCard extends ConsumerStatefulWidget {
  final String disruptionId;
  final Map<String, dynamic> booking;
  const _AffectedBookingCard({required this.disruptionId, required this.booking});

  @override
  ConsumerState<_AffectedBookingCard> createState() =>
      _AffectedBookingCardState();
}

class _AffectedBookingCardState extends ConsumerState<_AffectedBookingCard> {
  bool _saving = false;
  String? _error;

  Future<void> _swap(String bikeId, String label, {bool crossSite = false}) async {
    // Resolving removes our row from the provider's list, disposing
    // THIS state before the toast fires. Grab the messenger up front.
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).resolveDisruptionBooking(
            disruptionId: widget.disruptionId,
            bookingId: (widget.booking['bookingId'] ?? '').toString(),
            resolution: 'swapped',
            newBikeId: bikeId,
          );
      ref.invalidate(openDisruptionsProvider);
      messenger?.showSnackBar(SnackBar(
        content: Text(
          crossSite
              ? 'Swapped to $label · check Bike logistics for the move'
              : 'Swapped to $label · student notified',
        ),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: crossSite ? 5 : 3),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Cross-site + same-day swaps gate behind a confirmation dialog —
  /// no one wants to silently agree to "drive the bike to Belfast in
  /// the next 40 minutes". Future or same-site swaps go through
  /// without extra friction.
  Future<void> _maybeSwap(Map<String, dynamic> c, DateTime? startsAt) async {
    final bikeId = (c['bikeId'] ?? '').toString();
    final label = _AffectedBookingCardState._candidateLabel(c);
    final isCrossSite = c['isCrossSite'] == true;
    final fromLoc = (c['currentLocationName'] ?? '').toString();
    final isSameDay = startsAt != null && _isSameDay(startsAt, DateTime.now());
    if (isCrossSite && isSameDay) {
      final travelMins = (c['travelMinutes'] as num?)?.toInt() ?? 0;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final tf = DateFormat('HH:mm');
          // Concrete numbers tell the manager the move is realistic
          // (or not). "25 min drive, session in 1h 20" is much more
          // actionable than "someone will need to move the bike".
          final now = DateTime.now();
          final mins = startsAt.difference(now).inMinutes;
          final until = mins < 60
              ? '$mins min'
              : '${mins ~/ 60}h ${(mins % 60).toString().padLeft(2, '0')}';
          final tightness = travelMins > 0 && mins > 0
              ? (travelMins + 15 > mins
                  ? ' — **tight**'
                  : (travelMins * 2 > mins ? ' — borderline' : ''))
              : '';
          return AlertDialog(
            title: const Text('Cross-site swap'),
            content: Text(
              '$label is at ${fromLoc.isEmpty ? "another site" : fromLoc}. '
              'Session starts at ${tf.format(startsAt)} (in $until).\n\n'
              '${travelMins > 0 ? "$travelMins-min drive$tightness" : "Travel time isn't set up for that route — judge feasibility."}',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Pick another')),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Confirm swap'),
              ),
            ],
          );
        },
      );
      if (ok != true) return;
    }
    await _swap(bikeId, label, crossSite: isCrossSite);
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// True when the affected booking is still pending but the session
  /// it sits on has already ended. The card paints a "Past · needs
  /// cleanup" pill to flag the row, and the header banner offers a
  /// bulk-dismiss action.
  static bool _isStale(String resolution, Map<String, dynamic> b) {
    if (resolution != 'pending') return false;
    final ends = DateTime.tryParse(b['sessionEndsAt'] ?? '')?.toLocal();
    return ends != null && ends.isBefore(DateTime.now());
  }

  Future<void> _cancelWithApproval({bool confirm = true}) async {
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cancel this booking?'),
          content: Text(
              '${widget.booking['studentName']} will be told the school had to cancel due to the bike issue. The slot stays held.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel booking',
                  style: TextStyle(color: KsColors.danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    // Capture the messenger BEFORE the async work. Resolving the
    // booking removes it from openDisruptionsProvider, which rebuilds
    // the parent and disposes this row mid-callback — by then our
    // `context` is detached and ScaffoldMessenger.of(context) would
    // crash. The messenger reference stays valid because the parent
    // navigator outlives the disruption rows.
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).resolveDisruptionBooking(
            disruptionId: widget.disruptionId,
            bookingId: (widget.booking['bookingId'] ?? '').toString(),
            resolution: 'cancel_with_approval',
          );
      ref.invalidate(openDisruptionsProvider);
      messenger?.showSnackBar(const SnackBar(
        content: Text('Cancelled with approval — slot held'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Per-row equivalent of the header banner's "Dismiss past" button.
  /// Routes through the same cancel-with-approval endpoint but with a
  /// stale-specific note so the audit log distinguishes "manager
  /// chose to cancel due to bike issue" from "manager tidied up a
  /// post-session zombie row". Light-touch confirm dialog: the booking
  /// is already past, so no real consequences hinge on the click.
  Future<void> _dismissStale() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dismiss this row?'),
        content: Text(
            'The session for ${widget.booking['studentName']} has already passed. Dismissing closes the disruption row in the audit log. The booking and any charge on it stay as-is — they may have attended on a workaround bike, and we don’t auto-refund.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: KsColors.warning,
                foregroundColor: Colors.white),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).resolveDisruptionBooking(
            disruptionId: widget.disruptionId,
            bookingId: (widget.booking['bookingId'] ?? '').toString(),
            resolution: 'dismissed',
            notes: 'Session passed without resolution — dismissed.',
          );
      ref.invalidate(openDisruptionsProvider);
      messenger?.showSnackBar(const SnackBar(
        content: Text('Row dismissed'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    final resolution = (b['resolution'] ?? '').toString();
    final swapCandidates =
        ((b['swapCandidates'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final startsAt = DateTime.tryParse(b['sessionStartsAt'] ?? '')?.toLocal();
    final df = DateFormat('EEE d MMM');
    final tf = DateFormat('HH:mm');
    final whenStr = startsAt == null
        ? ''
        : '${df.format(startsAt)} · ${tf.format(startsAt)} ${b['locationName'] ?? ''}'.trim();

    final isPending = resolution == 'pending';

    return Container(
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      _Badge(
                        label: (b['courseName'] ?? '').toString(),
                        tone: _Tone.neutral,
                      ),
                      const SizedBox(width: 9),
                      Flexible(
                        child: Text(
                          (b['studentName'] ?? '').toString(),
                          style: GoogleFonts.plusJakartaSans(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: KsColors.ink),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ]),
                    if (whenStr.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(children: [
                        const Icon(Icons.event,
                            size: 14, color: KsColors.ink3),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(whenStr,
                              style: const TextStyle(
                                  color: KsColors.ink3, fontSize: 13),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ]),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _StateBadge(
                    resolution: resolution,
                    newBikeNickname: (b['newBikeNickname'] ?? '').toString(),
                    newBikeId: (b['newBikeId'] ?? '').toString(),
                  ),
                  if (_isStale(resolution, b)) ...[
                    const SizedBox(height: 4),
                    _StaleBadge(),
                  ],
                ],
              ),
            ],
          ),
          if (isPending) ...[
            const SizedBox(height: 14),
            Container(height: 1, color: KsColors.border),
            const SizedBox(height: 14),
            if (_isStale(resolution, b))
              // Past-due row: no point offering a swap (session's
              // gone). Show a focused single-button dismiss with
              // context, so the manager isn't going through the
              // generic "cancel this booking" flow for a tidy-up.
              _StaleDismissRow(
                saving: _saving,
                onDismiss: _dismissStale,
              )
            else if (swapCandidates.isNotEmpty)
              _CandidateGrid(
                candidates: swapCandidates,
                sessionStartsAt: startsAt,
                saving: _saving,
                onSwap: (c) => _maybeSwap(c, startsAt),
                onCancel: () => _cancelWithApproval(),
              )
            else
              _NoBikeFallback(
                saving: _saving,
                onApproveCancel: () => _cancelWithApproval(confirm: false),
              ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: KsColors.danger, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  static String _candidateLabel(Map<String, dynamic> c) {
    final nick = (c['bikeNickname'] ?? '').toString();
    final reg = (c['bikeRegistration'] ?? '').toString();
    if (nick.isEmpty && reg.isEmpty) return (c['bikeId'] ?? '').toString();
    return '$nick${reg.isEmpty ? '' : ' $reg'}'.trim();
  }
}

/// All candidate bikes shown as colour-coded tiles so the manager can
/// pick deliberately rather than blindly trusting the engine's first
/// pick. Three tones:
///   - green: same-location bike (drop-in swap)
///   - amber: cross-site, future session (logistics will handle the move)
///   - yellow: cross-site, same-day session (move needed soon — gated by
///     a confirm dialog upstream)
class _CandidateGrid extends StatelessWidget {
  final List<Map<String, dynamic>> candidates;
  final DateTime? sessionStartsAt;
  final bool saving;
  final void Function(Map<String, dynamic>) onSwap;
  final VoidCallback onCancel;
  const _CandidateGrid({
    required this.candidates,
    required this.sessionStartsAt,
    required this.saving,
    required this.onSwap,
    required this.onCancel,
  });

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final isToday = sessionStartsAt != null &&
        _sameDay(sessionStartsAt!, today);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Available swaps',
            style: GoogleFonts.plusJakartaSans(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: KsColors.ink3,
                letterSpacing: 0.5)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in candidates)
              _CandidateTile(
                candidate: c,
                sameDayCrossSite:
                    isToday && (c['isCrossSite'] == true),
                saving: saving,
                onTap: () => onSwap(c),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: saving ? null : onCancel,
            icon: const Icon(Icons.close, size: 14),
            label: const Text('None of these — cancel booking'),
            style: OutlinedButton.styleFrom(
              foregroundColor: KsColors.ink2,
              side: const BorderSide(color: KsColors.border2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

class _CandidateTile extends StatelessWidget {
  final Map<String, dynamic> candidate;
  final bool sameDayCrossSite;
  final bool saving;
  final VoidCallback onTap;
  const _CandidateTile({
    required this.candidate,
    required this.sameDayCrossSite,
    required this.saving,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final nick = (candidate['bikeNickname'] ?? '').toString();
    final reg = (candidate['bikeRegistration'] ?? '').toString();
    final loc = (candidate['currentLocationName'] ?? '').toString();
    final isCrossSite = candidate['isCrossSite'] == true;

    // Three colour tones. Same-site keeps the "drop-in swap" feel; a
    // future cross-site move is fine (logistics page picks it up);
    // same-day cross-site needs human attention.
    final Color fg, bg, border;
    final IconData icon;
    final String tag;
    if (sameDayCrossSite) {
      fg = KsColors.warning;
      bg = KsColors.warningTint;
      border = KsColors.warning.withValues(alpha: 0.55);
      icon = Icons.warning_amber_rounded;
      tag = 'Move needed today';
    } else if (isCrossSite) {
      fg = const Color(0xFF92632F); // amber-700, softer than warning
      bg = const Color(0xFFFAEFE0);
      border = const Color(0xFFE7C796);
      icon = Icons.route_outlined;
      tag = 'Cross-site';
    } else {
      fg = KsColors.success;
      bg = KsColors.successTint;
      border = KsColors.success.withValues(alpha: 0.4);
      icon = Icons.check_circle_outline;
      tag = 'On-site';
    }

    return SizedBox(
      width: 260,
      child: InkWell(
        onTap: saving ? null : onTap,
        borderRadius: BorderRadius.circular(KsRadius.md),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(KsRadius.md),
            border: Border.all(color: border, width: 1.2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 6),
                Text(tag,
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: fg,
                        letterSpacing: 0.4)),
                const Spacer(),
                Icon(Icons.swap_horiz, size: 16, color: fg),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Flexible(
                  child: Text(
                    nick.isEmpty
                        ? (candidate['bikeId'] ?? '').toString()
                        : nick,
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        color: KsColors.ink),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (reg.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(reg,
                      style: GoogleFonts.spaceMono(
                          fontSize: 11.5, color: KsColors.ink4)),
                ],
              ]),
              if (isCrossSite && loc.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.place_outlined,
                      size: 12, color: KsColors.ink3),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _crossSiteSubtitle(loc, candidate),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: KsColors.ink3, fontSize: 11.5),
                    ),
                  ),
                ]),
              ],
              if (candidate['tightFromPrior'] == true) ...[
                const SizedBox(height: 6),
                _PriorTightWarning(candidate: candidate),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _crossSiteSubtitle(String loc, Map<String, dynamic> c) {
    final mins = (c['travelMinutes'] as num?)?.toInt() ?? 0;
    if (mins > 0) return 'At $loc · $mins min away';
    return 'Currently at $loc';
  }
}

/// Inline warning chip that appears on a candidate tile when the
/// engine's prior-session check fired — the bike's previous booking
/// ends so close to this session's start that physically getting the
/// bike here on time looks doubtful. Non-blocking; the manager can
/// still pick the bike, they just see the risk first.
class _PriorTightWarning extends StatelessWidget {
  final Map<String, dynamic> candidate;
  const _PriorTightWarning({required this.candidate});

  @override
  Widget build(BuildContext context) {
    final endsRaw = (candidate['priorSessionEndsAt'] ?? '').toString();
    final priorLoc = (candidate['priorSessionLocation'] ?? '').toString();
    final ends = DateTime.tryParse(endsRaw)?.toLocal();
    final tf = DateFormat('HH:mm');
    final text = ends != null && priorLoc.isNotEmpty
        ? 'Just finished at $priorLoc · ${tf.format(ends)}'
        : 'Bike has a back-to-back commitment — move may be tight';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: KsColors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(KsRadius.pill),
        border: Border.all(color: KsColors.danger.withValues(alpha: 0.4)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.schedule, size: 12, color: KsColors.danger),
        const SizedBox(width: 5),
        Flexible(
          child: Text(text,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: KsColors.danger)),
        ),
      ]),
    );
  }
}

class _NoBikeFallback extends StatelessWidget {
  final bool saving;
  final VoidCallback onApproveCancel;
  const _NoBikeFallback({required this.saving, required this.onApproveCancel});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        const SizedBox(
          width: 320,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline,
                  size: 18, color: KsColors.warning),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No suitable bike free — needs manager approval. Slot stays held for the student.',
                  style: TextStyle(
                      color: KsColors.ink2,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        ElevatedButton.icon(
          onPressed: saving ? null : onApproveCancel,
          icon: const Icon(Icons.verified_user_outlined, size: 14),
          label: const Text('Approve cancellation'),
          style: ElevatedButton.styleFrom(
            backgroundColor: KsColors.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// Inline action row shown when an affected booking is past-due. Same
/// resolution as cancel-with-approval but a softer "Dismiss · session
/// passed" framing — we're tidying, not making a judgement call.
class _StaleDismissRow extends StatelessWidget {
  final bool saving;
  final VoidCallback onDismiss;
  const _StaleDismissRow({required this.saving, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        const SizedBox(
          width: 360,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.history_toggle_off,
                  size: 18, color: KsColors.warning),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Session ended without resolution. Dismissing closes the row and notes "session passed" in the audit log.',
                  style: TextStyle(
                      color: KsColors.ink2,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        ElevatedButton.icon(
          onPressed: saving ? null : onDismiss,
          icon: const Icon(Icons.clear_all, size: 14),
          label: const Text('Dismiss · session passed'),
          style: ElevatedButton.styleFrom(
            backgroundColor: KsColors.warning,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            textStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// Small pill that flags an affected booking whose session has
/// already ended. Sits alongside the main resolution badge so the
/// admin can spot zombies at a glance and either resolve manually or
/// use the bulk "Dismiss past" action.
class _StaleBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: KsColors.warningTint,
        borderRadius: BorderRadius.circular(KsRadius.pill),
        border: Border.all(color: KsColors.warning.withValues(alpha: 0.45)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.history_toggle_off,
            size: 12, color: KsColors.warning),
        const SizedBox(width: 5),
        Text('Past · needs cleanup',
            style: GoogleFonts.plusJakartaSans(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: KsColors.warning,
                letterSpacing: 0.3)),
      ]),
    );
  }
}

class _StateBadge extends StatelessWidget {
  final String resolution;
  final String newBikeNickname;
  final String newBikeId;
  const _StateBadge({
    required this.resolution,
    required this.newBikeNickname,
    required this.newBikeId,
  });

  @override
  Widget build(BuildContext context) {
    switch (resolution) {
      case 'swapped':
        final label = newBikeNickname.isNotEmpty ? newBikeNickname : newBikeId;
        return _Badge(
          label: 'Swapped → $label',
          tone: _Tone.success,
          icon: Icons.check,
        );
      case 'cancelled':
      case 'cancel_with_approval':
        return const _Badge(
          label: 'Cancelled · slot held',
          tone: _Tone.warning,
          icon: Icons.shield_outlined,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

enum _Tone { neutral, success, warning, danger }

class _Badge extends StatelessWidget {
  final String label;
  final _Tone tone;
  final IconData? icon;
  const _Badge({required this.label, required this.tone, this.icon});

  @override
  Widget build(BuildContext context) {
    late Color fg, bg;
    switch (tone) {
      case _Tone.neutral:
        fg = KsColors.ink2;
        bg = KsColors.surface3;
        break;
      case _Tone.success:
        fg = KsColors.success;
        bg = KsColors.successTint;
        break;
      case _Tone.warning:
        fg = KsColors.warning;
        bg = KsColors.warningTint;
        break;
      case _Tone.danger:
        fg = KsColors.danger;
        bg = KsColors.dangerTint;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.w700, fontSize: 11)),
        ],
      ),
    );
  }
}
