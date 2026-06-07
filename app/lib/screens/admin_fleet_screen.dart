// Admin Fleet — bike table matching design/admin-fleet.jsx.
//
// Layout:
//   - Header: title + "{ready} ready · {down} unavailable across {sites} sites"
//     subtitle + "Add bike" action button
//   - Single pill segmented filter: All N / Ready N / Unavailable N
//   - Table: Bike | Reg | Category | Transmission | Home | Current | Status | (action)
//
// Per-bike action: "Take offline" (ready bikes) or "Restore" (anything else),
// firing /bikes/{id}/offline or /bikes/{id}/restore and refreshing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../theme/theme.dart';

final _fleetFilterProvider = StateProvider.autoDispose<String>((_) => 'all');
final _fleetLocationFilterProvider =
    StateProvider.autoDispose<String>((_) => 'all');

class AdminFleetScreen extends ConsumerWidget {
  const AdminFleetScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(fleetProvider);
    final filter = ref.watch(_fleetFilterProvider);
    final locFilter = ref.watch(_fleetLocationFilterProvider);

    final allBikes = async.maybeWhen(data: (l) => l, orElse: () => const <FleetBike>[]);
    final readyCount = allBikes.where((b) => b.status == 'ready').length;
    final downCount = allBikes.length - readyCount;
    final sites = allBikes.map((b) => b.currentLocationId).toSet().length;

    final locationOptions = <(String, String)>[];
    final seenLocs = <String>{};
    for (final b in allBikes) {
      if (b.currentLocationId.isEmpty || !seenLocs.add(b.currentLocationId)) {
        continue;
      }
      locationOptions.add((
        b.currentLocationId,
        b.currentLocationName.isEmpty ? b.currentLocationId : b.currentLocationName,
      ));
    }
    locationOptions.sort((a, b) => a.$2.compareTo(b.$2));
    final locationCounts = <String, int>{
      for (final (id, _) in locationOptions)
        id: allBikes.where((b) => b.currentLocationId == id).length,
    };

    final filtered = allBikes.where((b) {
      final statusOK = switch (filter) {
        'ready' => b.status == 'ready',
        'down' => b.status != 'ready',
        _ => true,
      };
      final locOK = locFilter == 'all' || b.currentLocationId == locFilter;
      return statusOK && locOK;
    }).toList();

    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(fleetProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _Header(
            ready: readyCount,
            down: downCount,
            sites: sites,
            onAdd: () => _showAddBikeStub(context),
            showCounts: !async.isLoading,
          ),
          const SizedBox(height: 16),
          _FilterSeg(
            value: filter,
            counts: (allBikes.length, readyCount, downCount),
            onChanged: (v) =>
                ref.read(_fleetFilterProvider.notifier).state = v,
          ),
          if (locationOptions.isNotEmpty) ...[
            const SizedBox(height: 10),
            _LocationFilter(
              value: locFilter,
              allCount: allBikes.length,
              locations: locationOptions,
              counts: locationCounts,
              onChanged: (v) => ref
                  .read(_fleetLocationFilterProvider.notifier)
                  .state = v,
            ),
          ],
          const SizedBox(height: 16),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                  child:
                      CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => Text('Couldn’t load.\n$e'),
            data: (_) {
              if (filtered.isEmpty) {
                final locLabel = locFilter == 'all'
                    ? ''
                    : locationOptions
                        .firstWhere((o) => o.$1 == locFilter,
                            orElse: () => (locFilter, locFilter))
                        .$2;
                return _EmptyState(filter: filter, locationName: locLabel);
              }
              return Container(
                decoration: BoxDecoration(
                  color: KsColors.surface,
                  borderRadius: BorderRadius.circular(KsRadius.lg),
                  border: Border.all(color: KsColors.border),
                  boxShadow: KsShadows.sh1,
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  _HeaderRow(),
                  ...filtered.asMap().entries.map((e) => _BikeRow(
                        bike: e.value,
                        last: e.key == filtered.length - 1,
                      )),
                ]),
              );
            },
          ),
        ],
      ),
    );
  }

  void _showAddBikeStub(BuildContext context) {
    // Add-bike editor matching the design's modal is still pending. The
    // backend route already exists (`POST /bikes`); wiring the form is
    // a separate piece of work.
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Add-bike form coming next — backend route already exists.'),
      behavior: SnackBarBehavior.floating,
    ));
  }
}

// ===== Header =====

class _Header extends StatelessWidget {
  final int ready;
  final int down;
  final int sites;
  final VoidCallback onAdd;
  final bool showCounts;
  const _Header({
    required this.ready,
    required this.down,
    required this.sites,
    required this.onAdd,
    required this.showCounts,
  });

  @override
  Widget build(BuildContext context) {
    final sub = !showCounts
        ? 'Loading fleet…'
        : '$ready ready · $down unavailable across $sites site${sites == 1 ? '' : 's'}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Bike fleet',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: KsColors.ink,
                      letterSpacing: -0.6)),
              const SizedBox(height: 4),
              Text(sub,
                  style:
                      const TextStyle(color: KsColors.ink3, fontSize: 13)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ElevatedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add bike'),
        ),
      ],
    );
  }
}

// ===== Single segmented filter =====

class _FilterSeg extends StatelessWidget {
  final String value;
  final (int, int, int) counts; // (all, ready, down)
  final ValueChanged<String> onChanged;
  const _FilterSeg({
    required this.value,
    required this.counts,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final (all, ready, down) = counts;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: KsColors.surface2,
        borderRadius: BorderRadius.circular(KsRadius.pill),
        border: Border.all(color: KsColors.border),
      ),
      child: Wrap(
        children: [
          _segBtn('all', 'All $all'),
          _segBtn('ready', 'Ready $ready'),
          _segBtn('down', 'Unavailable $down'),
        ],
      ),
    );
  }

  Widget _segBtn(String v, String label) {
    final on = value == v;
    return InkWell(
      onTap: () => onChanged(v),
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: on ? KsColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          boxShadow: on ? KsShadows.sh1 : null,
        ),
        child: Text(label,
            style: GoogleFonts.plusJakartaSans(
                color: on ? KsColors.ink : KsColors.ink3,
                fontWeight: FontWeight.w700,
                fontSize: 13)),
      ),
    );
  }
}

// ===== Location filter (current-location segmented control) =====

class _LocationFilter extends StatelessWidget {
  final String value;
  final int allCount;
  final List<(String, String)> locations; // (id, name)
  final Map<String, int> counts;
  final ValueChanged<String> onChanged;
  const _LocationFilter({
    required this.value,
    required this.allCount,
    required this.locations,
    required this.counts,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: KsColors.surface2,
        borderRadius: BorderRadius.circular(KsRadius.pill),
        border: Border.all(color: KsColors.border),
      ),
      child: Wrap(
        children: [
          _btn('all', 'All sites $allCount'),
          for (final loc in locations)
            _btn(loc.$1, '${loc.$2} ${counts[loc.$1] ?? 0}'),
        ],
      ),
    );
  }

  Widget _btn(String v, String label) {
    final on = value == v;
    return InkWell(
      onTap: () => onChanged(v),
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: on ? KsColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          boxShadow: on ? KsShadows.sh1 : null,
        ),
        child: Text(label,
            style: GoogleFonts.plusJakartaSans(
                color: on ? KsColors.ink : KsColors.ink3,
                fontWeight: FontWeight.w700,
                fontSize: 13)),
      ),
    );
  }
}

// ===== Table header =====

class _HeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: const BoxDecoration(
        color: KsColors.surface2,
        border: Border(bottom: BorderSide(color: KsColors.border)),
      ),
      child: Row(children: const [
        Expanded(flex: 4, child: _Col('Bike')),
        Expanded(flex: 2, child: _Col('Reg')),
        Expanded(flex: 2, child: _Col('Category')),
        Expanded(flex: 3, child: _Col('Transmission')),
        Expanded(flex: 2, child: _Col('Home')),
        Expanded(flex: 2, child: _Col('Current')),
        Expanded(flex: 2, child: _Col('Status')),
        SizedBox(width: 120),
      ]),
    );
  }
}

class _Col extends StatelessWidget {
  final String label;
  const _Col(this.label);
  @override
  Widget build(BuildContext context) => Text(label.toUpperCase(),
      style: GoogleFonts.plusJakartaSans(
          color: KsColors.ink3,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5));
}

// ===== Bike row =====

class _BikeRow extends ConsumerStatefulWidget {
  final FleetBike bike;
  final bool last;
  const _BikeRow({required this.bike, required this.last});
  @override
  ConsumerState<_BikeRow> createState() => _BikeRowState();
}

class _BikeRowState extends ConsumerState<_BikeRow> {
  bool _busy = false;

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).restoreBike(widget.bike.id);
      ref.invalidate(fleetProvider);
      ref.invalidate(openDisruptionsProvider);
    } catch (e) {
      if (mounted) _toast('Could not restore: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _takeOffline() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KsColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
      ),
      builder: (_) => _TakeOfflineSheet(bike: widget.bike),
    );
    if (result != null) {
      ref.invalidate(fleetProvider);
      ref.invalidate(openDisruptionsProvider);
      ref.invalidate(logisticsForDateProvider);
      final n = ((result['affectedBookings'] as List?) ?? const []).length;
      _toast(n == 0
          ? '${widget.bike.nickname} taken offline.'
          : '${widget.bike.nickname} offline · $n booking${n == 1 ? '' : 's'} need reassignment.');
    }
  }

  void _toast(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? KsColors.danger : KsColors.ink,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bike;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: widget.last
              ? BorderSide.none
              : const BorderSide(color: KsColors.border),
        ),
      ),
      child: Row(children: [
        Expanded(
          flex: 4,
          child: Row(children: [
            _BikeGlyph(category: b.category),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                b.nickname.isEmpty
                    ? '${b.make} ${b.model}'.trim()
                    : b.nickname,
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w700,
                    color: KsColors.ink,
                    fontSize: 13.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
        Expanded(
          flex: 2,
          child: Text(b.registration.isEmpty ? '—' : b.registration,
              style: b.registration.isEmpty
                  ? const TextStyle(color: KsColors.ink3, fontSize: 13)
                  : ksMono(size: 12.5, weight: FontWeight.w700)),
        ),
        Expanded(flex: 2, child: _CategoryBadge(category: b.category)),
        Expanded(
          flex: 3,
          child: Text(
            b.engineCc > 0
                ? '${b.engineCc}cc · ${b.transmission}'
                : b.transmission,
            style: const TextStyle(color: KsColors.ink2, fontSize: 13),
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(b.homeLocationName.isEmpty ? '—' : b.homeLocationName,
              style: const TextStyle(color: KsColors.ink2, fontSize: 13)),
        ),
        Expanded(
          flex: 2,
          child: Row(children: [
            if (b.isCrossSite) ...[
              const Icon(Icons.route_outlined,
                  size: 14, color: KsColors.warning),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                  b.currentLocationName.isEmpty
                      ? '—'
                      : b.currentLocationName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: b.isCrossSite
                          ? KsColors.warning
                          : KsColors.ink2,
                      fontWeight: b.isCrossSite
                          ? FontWeight.w700
                          : FontWeight.w500,
                      fontSize: 13)),
            ),
          ]),
        ),
        Expanded(flex: 2, child: _StatusBadge(b.status)),
        SizedBox(
          width: 120,
          child: _busy
              ? const Center(
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : b.status == 'ready'
                  ? OutlinedButton(
                      onPressed: _takeOffline,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: KsColors.ink2,
                        side: const BorderSide(color: KsColors.border2),
                        minimumSize: const Size(0, 32),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10),
                        textStyle: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                      child: const Text('Take offline'),
                    )
                  : ElevatedButton(
                      onPressed: _restore,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: KsColors.primaryTint,
                        foregroundColor: KsColors.primaryDeep,
                        elevation: 0,
                        minimumSize: const Size(0, 32),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10),
                        textStyle: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                      child: const Text('Restore'),
                    ),
        ),
      ]),
    );
  }
}

// ===== Coloured bike glyph =====

/// Bike icon coloured by category: A1 indigo, A2 amber, A red. Matches
/// the design's `BikeGlyph` so categories scan visually in the table.
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

// ===== Category badge =====

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
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
        child: Text(category.isEmpty ? '—' : category,
            style: GoogleFonts.plusJakartaSans(
                color: fg, fontWeight: FontWeight.w800, fontSize: 11)),
      ),
    );
  }
}

// ===== Status badge =====

class _StatusBadge extends StatelessWidget {
  final String s;
  const _StatusBadge(this.s);
  @override
  Widget build(BuildContext context) {
    late Color fg, bg;
    switch (s) {
      case 'ready':
        fg = KsColors.success;
        bg = KsColors.successTint;
        break;
      case 'offline':
        fg = KsColors.danger;
        bg = KsColors.dangerTint;
        break;
      case 'in_use':
        fg = KsColors.primary;
        bg = KsColors.primaryTint;
        break;
      default:
        fg = KsColors.ink3;
        bg = KsColors.surface3;
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
        child: Text(_humanStatus(s),
            style: GoogleFonts.plusJakartaSans(
                color: fg, fontWeight: FontWeight.w700, fontSize: 11)),
      ),
    );
  }
}

String _humanStatus(String s) {
  switch (s) {
    case 'ready':
      return 'Ready';
    case 'offline':
      return 'Offline';
    case 'in_use':
      return 'In use';
  }
  return s;
}

// ===== Empty state =====

class _EmptyState extends StatelessWidget {
  final String filter;
  final String locationName; // empty = no location filter
  const _EmptyState({required this.filter, this.locationName = ''});

  @override
  Widget build(BuildContext context) {
    final hasLoc = locationName.isNotEmpty;
    final msg = switch (filter) {
      'ready' => hasLoc
          ? 'No ready bikes at $locationName'
          : 'No bikes are ready right now',
      'down' => hasLoc
          ? 'No unavailable bikes at $locationName'
          : 'No bikes are unavailable — everything’s in service',
      _ => hasLoc
          ? 'No bikes at $locationName right now'
          : 'No bikes yet — add the first one to start scheduling',
    };
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(children: [
        const Icon(Icons.two_wheeler_rounded,
            size: 48, color: KsColors.ink4),
        const SizedBox(height: 12),
        Text(msg,
            style: GoogleFonts.plusJakartaSans(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: KsColors.ink)),
      ]),
    );
  }
}

// ===== Take-offline sheet (unchanged from before) =====

class _TakeOfflineSheet extends ConsumerStatefulWidget {
  final FleetBike bike;
  const _TakeOfflineSheet({required this.bike});
  @override
  ConsumerState<_TakeOfflineSheet> createState() => _TakeOfflineSheetState();
}

class _TakeOfflineSheetState extends ConsumerState<_TakeOfflineSheet> {
  final _notesCtrl = TextEditingController();
  String _reason = 'damaged';
  bool _saving = false;
  String? _error;

  static const _reasons = [
    ('damaged', 'Damaged'),
    ('broken', 'Broken'),
    ('mechanic', 'At mechanic'),
    ('off_road', 'Off-road'),
    ('other', 'Other'),
  ];

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiClientProvider).takeBikeOffline(
            bikeId: widget.bike.id,
            reason: _reason,
            notes: _notesCtrl.text.trim().isEmpty
                ? null
                : _notesCtrl.text.trim(),
          );
      if (mounted) Navigator.pop(context, res);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not take offline.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  height: 4,
                  width: 36,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: KsColors.border2,
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                  ),
                ),
              ),
              Text(
                  'Take ${widget.bike.nickname.isEmpty ? widget.bike.id : widget.bike.nickname} offline',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: KsColors.ink)),
              const SizedBox(height: 4),
              const Text(
                'Stops the bike appearing in availability. Any affected '
                'bookings will be flagged for reassignment.',
                style: TextStyle(color: KsColors.ink3, fontSize: 12),
              ),
              const SizedBox(height: 16),
              Text('Reason',
                  style: GoogleFonts.plusJakartaSans(
                      color: KsColors.ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _reasons
                    .map((r) => InkWell(
                          onTap: () => setState(() => _reason = r.$1),
                          borderRadius: BorderRadius.circular(KsRadius.pill),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: _reason == r.$1
                                  ? KsColors.warningTint
                                  : KsColors.surface2,
                              borderRadius:
                                  BorderRadius.circular(KsRadius.pill),
                              border: Border.all(
                                color: _reason == r.$1
                                    ? KsColors.warning.withValues(alpha: 0.5)
                                    : KsColors.border,
                                width: _reason == r.$1 ? 1.5 : 1,
                              ),
                            ),
                            child: Text(r.$2,
                                style: TextStyle(
                                  color: _reason == r.$1
                                      ? KsColors.warning
                                      : KsColors.ink2,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                )),
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _notesCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'e.g. Front brake pads need replacing',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: KsColors.dangerTint,
                    borderRadius: BorderRadius.circular(KsRadius.md),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(color: KsColors.danger)),
                ),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                style: ElevatedButton.styleFrom(
                    backgroundColor: KsColors.warning),
                child: _saving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : const Text('Take offline'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
