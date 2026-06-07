// Admin Logistics — derived "bikes to move" view for a given day.
//
// Defaults to tomorrow (the typical "end of today, plan for tomorrow"
// question). Read-only first cut: the marker-moved action comes in a
// follow-up with a small backend endpoint.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../state/providers.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';

final _logisticsDateProvider = StateProvider.autoDispose<DateTime>((_) =>
    DateTime.now().add(const Duration(days: 1)));

class AdminLogisticsScreen extends ConsumerWidget {
  const AdminLogisticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = ref.watch(_logisticsDateProvider);
    final async = ref.watch(logisticsForDateProvider(dateKey(date)));
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async =>
          ref.invalidate(logisticsForDateProvider(dateKey(date))),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Bike logistics',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 28, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.6)),
          const SizedBox(height: 6),
          const Text(
            'Bikes that need to be at a different site for the next day’s sessions.',
            style: TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 18),
          _DatePicker(date: date, onPick: (d) {
            ref.read(_logisticsDateProvider.notifier).state = d;
          }),
          const SizedBox(height: 20),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => Text('Couldn’t load.\n$e'),
            data: (data) {
              final totalMoves = data['totalMoves'] ?? 0;
              final destinations = ((data['destinations'] as List?) ?? const []).cast<Map<String, dynamic>>();
              if (destinations.isEmpty) {
                return _EmptyState(date: date);
              }
              return Column(children: [
                _TotalRow(totalMoves: totalMoves, dateStr: data['date'] ?? ''),
                const SizedBox(height: 14),
                ...destinations.map((d) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _DestinationCard(destination: d),
                    )),
              ]);
            },
          ),
        ],
      ),
    );
  }
}

class _DatePicker extends StatelessWidget {
  final DateTime date;
  final ValueChanged<DateTime> onPick;
  const _DatePicker({required this.date, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final t = DateTime(today.year, today.month, today.day);
    final selected = DateTime(date.year, date.month, date.day);
    final df = DateFormat('EEEE, d MMMM');

    return Row(children: [
      OutlinedButton.icon(
        onPressed: () => onPick(selected.subtract(const Duration(days: 1))),
        icon: const Icon(Icons.chevron_left, size: 16),
        label: const Text('Prev'),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: selected,
              firstDate: t.subtract(const Duration(days: 365)),
              lastDate: t.add(const Duration(days: 365)),
            );
            if (picked != null) onPick(picked);
          },
          borderRadius: BorderRadius.circular(KsRadius.md),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: KsColors.surface,
              borderRadius: BorderRadius.circular(KsRadius.md),
              border: Border.all(color: KsColors.border),
            ),
            child: Row(children: [
              const Icon(Icons.event, size: 16, color: KsColors.primaryDeep),
              const SizedBox(width: 8),
              Expanded(
                child: Text(df.format(selected),
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700, color: KsColors.ink, fontSize: 14)),
              ),
              if (_isSameDay(selected, t.add(const Duration(days: 1))))
                _tagPill('Tomorrow', KsColors.primaryDeep, KsColors.primaryTint),
              if (_isSameDay(selected, t))
                _tagPill('Today', KsColors.success, KsColors.successTint),
            ]),
          ),
        ),
      ),
      const SizedBox(width: 8),
      OutlinedButton.icon(
        onPressed: () => onPick(selected.add(const Duration(days: 1))),
        icon: const Icon(Icons.chevron_right, size: 16),
        label: const Text('Next'),
      ),
      const SizedBox(width: 8),
      TextButton(
        onPressed: () => onPick(t.add(const Duration(days: 1))),
        child: const Text('Tomorrow'),
      ),
    ]);
  }

  Widget _tagPill(String label, Color fg, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
        child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 11)),
      );

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _TotalRow extends StatelessWidget {
  final int totalMoves;
  final String dateStr;
  const _TotalRow({required this.totalMoves, required this.dateStr});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: totalMoves == 0 ? KsColors.successTint : KsColors.primaryTint,
        borderRadius: BorderRadius.circular(KsRadius.md),
        border: Border.all(
          color: (totalMoves == 0 ? KsColors.success : KsColors.primary).withValues(alpha: 0.3),
        ),
      ),
      child: Row(children: [
        Icon(
          totalMoves == 0 ? Icons.check_circle : Icons.local_shipping_outlined,
          color: totalMoves == 0 ? KsColors.success : KsColors.primaryDeep,
          size: 20,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            totalMoves == 0
                ? 'All bikes are at the right sites.'
                : '$totalMoves bike${totalMoves == 1 ? '' : 's'} to move for $dateStr.',
            style: TextStyle(
              color: totalMoves == 0 ? KsColors.success : KsColors.primaryDeep,
              fontWeight: FontWeight.w700, fontSize: 14,
            ),
          ),
        ),
      ]),
    );
  }
}

class _DestinationCard extends StatelessWidget {
  final Map<String, dynamic> destination;
  const _DestinationCard({required this.destination});

  @override
  Widget build(BuildContext context) {
    final moves = ((destination['moves'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return Container(
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: const BoxDecoration(
              color: KsColors.surface2,
              border: Border(bottom: BorderSide(color: KsColors.border)),
            ),
            child: Row(children: [
              const Icon(Icons.place_outlined, color: KsColors.warning, size: 18),
              const SizedBox(width: 8),
              Text(destination['locationName'] ?? '',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 15)),
              const SizedBox(width: 6),
              Text('needs',
                  style: GoogleFonts.plusJakartaSans(
                      color: KsColors.ink3, fontWeight: FontWeight.w600, fontSize: 13)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: KsColors.warningTint,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                ),
                child: Text(
                    '${moves.length} bike${moves.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                        color: KsColors.warning,
                        fontWeight: FontWeight.w700,
                        fontSize: 11)),
              ),
            ]),
          ),
          ...moves.asMap().entries.map((entry) => _MoveRow(
                move: entry.value,
                last: entry.key == moves.length - 1,
              )),
        ],
      ),
    );
  }
}

class _MoveRow extends ConsumerStatefulWidget {
  final Map<String, dynamic> move;
  final bool last;
  const _MoveRow({required this.move, required this.last});
  @override
  ConsumerState<_MoveRow> createState() => _MoveRowState();
}

class _MoveRowState extends ConsumerState<_MoveRow> {
  bool _saving = false;

  Future<void> _markMoved() async {
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).moveBike(
            bikeId: (widget.move['bikeId'] ?? '').toString(),
            locationId: (widget.move['toLocationId'] ?? '').toString(),
          );
      // Invalidate the whole family — both the visible date and Overview's
      // tomorrow-cache share this provider.
      ref.invalidate(logisticsForDateProvider);
      ref.invalidate(fleetProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Marked ${_bikeLabel(widget.move)} as moved'),
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not mark moved: $e'),
            backgroundColor: KsColors.danger,
            behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _bikeLabel(Map<String, dynamic> m) {
    final nickname = (m['bikeNickname'] ?? '').toString();
    if (nickname.isNotEmpty) return nickname;
    final reg = (m['bikeRegistration'] ?? '').toString();
    if (reg.isNotEmpty) return reg;
    return (m['bikeId'] ?? '').toString();
  }

  @override
  Widget build(BuildContext context) {
    final move = widget.move;
    final startsAt = DateTime.tryParse(move['sessionStartsAt'] ?? '')?.toLocal();
    final nickname = (move['bikeNickname'] ?? '').toString();
    final reg = (move['bikeRegistration'] ?? '').toString();
    final category = (move['bikeCategory'] ?? '').toString();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: widget.last ? BorderSide.none : const BorderSide(color: KsColors.border),
        ),
      ),
      child: Row(children: [
        _BikeGlyph(category: category),
        const SizedBox(width: 12),
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(
                    nickname.isEmpty ? _bikeLabel(move) : nickname,
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700, color: KsColors.ink, fontSize: 13.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (reg.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(reg, style: ksMono(size: 12, weight: FontWeight.w700)),
                ],
                const SizedBox(width: 8),
                _CategoryBadge(category: category),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.route_outlined, size: 14, color: KsColors.warning),
                const SizedBox(width: 5),
                Text(move['fromLocationName'] ?? '',
                    style: const TextStyle(
                        color: KsColors.warning,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                const Icon(Icons.arrow_forward, size: 12, color: KsColors.ink3),
                const SizedBox(width: 6),
                Text(move['toLocationName'] ?? '',
                    style: const TextStyle(
                        color: KsColors.ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ]),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (startsAt != null)
              Text(DateFormat('HH:mm').format(startsAt),
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 14)),
            Text('${move['courseTypeName']} · ${move['studentName']}',
                style: const TextStyle(color: KsColors.ink3, fontSize: 11)),
          ],
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 110,
          child: OutlinedButton.icon(
            onPressed: _saving ? null : _markMoved,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check, size: 14),
            label: const Text('Move done', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: KsColors.success,
              side: BorderSide(color: KsColors.success.withValues(alpha: 0.4)),
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ),
      ]),
    );
  }
}

// ===== Coloured bike glyph (kept in sync with the fleet screen) =====

class _BikeGlyph extends StatelessWidget {
  final String category;
  const _BikeGlyph({required this.category});

  @override
  Widget build(BuildContext context) {
    final colour = switch (category) {
      'A' => KsColors.danger,
      'A2' => KsColors.warning,
      _ => KsColors.primary,
    };
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(KsRadius.md),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.two_wheeler_rounded, color: colour, size: 20),
    );
  }
}

class _CategoryBadge extends StatelessWidget {
  final String category;
  const _CategoryBadge({required this.category});

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = switch (category) {
      'A' => (KsColors.danger, KsColors.dangerTint),
      'A2' => (KsColors.warning, KsColors.warningTint),
      _ => (KsColors.primaryDeep, KsColors.primaryTint),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
      child: Text(category.isEmpty ? '—' : category,
          style: GoogleFonts.plusJakartaSans(
              color: fg, fontWeight: FontWeight.w800, fontSize: 11)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final DateTime date;
  const _EmptyState({required this.date});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(children: [
        const Icon(Icons.local_shipping_outlined, size: 48, color: KsColors.ink4),
        const SizedBox(height: 12),
        Text('Nothing to move',
            style: GoogleFonts.plusJakartaSans(
                fontSize: 16, fontWeight: FontWeight.w700, color: KsColors.ink)),
        const SizedBox(height: 4),
        Text('Every bike is already where it’s needed for ${DateFormat('EEE d MMM').format(date)}.',
            style: const TextStyle(color: KsColors.ink2)),
      ]),
    );
  }
}
