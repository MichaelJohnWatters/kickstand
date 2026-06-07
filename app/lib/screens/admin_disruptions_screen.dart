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
            error: (e, _) => Text('Couldn’t load.\n$e'),
            data: (rows) {
              if (rows.isEmpty) return const _EmptyState();
              return Column(
                children: [
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

  Future<void> _swap(String bikeId, String label) async {
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
      if (mounted) _toast('Swapped to $label · student notified');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _cancelWithApproval({bool confirm = true}) async {
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Cancel this booking?'),
          content: Text(
              '${widget.booking['studentName']} will be told the school had to cancel due to the bike issue. The slot stays held.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Cancel booking',
                  style: TextStyle(color: KsColors.danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
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
      if (mounted) _toast('Cancelled with approval — slot held');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
    ));
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
    final suggestion = swapCandidates.isNotEmpty ? swapCandidates.first : null;

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
              _StateBadge(
                resolution: resolution,
                newBikeNickname: (b['newBikeNickname'] ?? '').toString(),
                newBikeId: (b['newBikeId'] ?? '').toString(),
              ),
            ],
          ),
          if (isPending) ...[
            const SizedBox(height: 14),
            Container(height: 1, color: KsColors.border),
            const SizedBox(height: 14),
            if (suggestion != null)
              _SuggestionRow(
                candidate: suggestion,
                saving: _saving,
                onSwap: () => _swap(
                  (suggestion['bikeId'] ?? '').toString(),
                  _candidateLabel(suggestion),
                ),
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

class _SuggestionRow extends StatelessWidget {
  final Map<String, dynamic> candidate;
  final bool saving;
  final VoidCallback onSwap;
  final VoidCallback onCancel;
  const _SuggestionRow({
    required this.candidate,
    required this.saving,
    required this.onSwap,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final nick = (candidate['bikeNickname'] ?? '').toString();
    final reg = (candidate['bikeRegistration'] ?? '').toString();
    final isCrossSite = candidate['isCrossSite'] == true;

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        SizedBox(
          width: 280,
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: KsColors.successTint,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                ),
                child: const Icon(Icons.auto_awesome,
                    color: KsColors.success, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isCrossSite
                          ? 'Suggested swap — cross-site'
                          : 'Suggested swap — suitable & free here',
                      style: const TextStyle(
                          color: KsColors.ink3,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Row(children: [
                      Flexible(
                        child: Text(
                          nick.isEmpty ? (candidate['bikeId'] ?? '').toString() : nick,
                          style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: KsColors.ink),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (reg.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(reg,
                            style: GoogleFonts.spaceMono(
                                fontSize: 12, color: KsColors.ink4)),
                      ],
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          OutlinedButton.icon(
            onPressed: saving ? null : onCancel,
            icon: const Icon(Icons.close, size: 14),
            label: const Text('No bike — cancel'),
            style: OutlinedButton.styleFrom(
              foregroundColor: KsColors.ink2,
              side: const BorderSide(color: KsColors.border2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: saving ? null : onSwap,
            icon: const Icon(Icons.swap_horiz, size: 14),
            label: const Text('Swap bike'),
            style: ElevatedButton.styleFrom(
              backgroundColor: KsColors.success,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
      ],
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
