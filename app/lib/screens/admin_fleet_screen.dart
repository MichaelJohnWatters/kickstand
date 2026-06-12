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
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../state/school.dart';
import '../theme/tokens.dart';
import '../theme/theme.dart';
import '../util/bike_warnings.dart';
import '../util/gov_links.dart';
import '../widgets/empty_state.dart';

final _fleetFilterProvider = StateProvider.autoDispose<String>((_) => 'all');
final _fleetLocationFilterProvider =
    StateProvider.autoDispose<String>((_) => 'all');
final _fleetCategoryFilterProvider =
    StateProvider.autoDispose<String>((_) => 'all'); // all | A1 | A2 | A
final _fleetDocsFilterProvider =
    StateProvider.autoDispose<String>((_) => 'all'); // all | warn | urgent | expired | unknown
final _fleetSearchProvider = StateProvider.autoDispose<String>((_) => '');

Future<void> _showAddBikeSheet(BuildContext context, WidgetRef ref) async {
  final created = await showModalBottomSheet<FleetBike>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => const _AddBikeSheet(),
  );
  if (created != null) {
    ref.invalidate(fleetProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Added ${created.nickname.isEmpty ? '${created.make} ${created.model}'.trim() : created.nickname}.',
        ),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

class AdminFleetScreen extends ConsumerWidget {
  const AdminFleetScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(fleetProvider);
    final filter = ref.watch(_fleetFilterProvider);
    final locFilter = ref.watch(_fleetLocationFilterProvider);
    final catFilter = ref.watch(_fleetCategoryFilterProvider);
    final docsFilter = ref.watch(_fleetDocsFilterProvider);
    final query = ref.watch(_fleetSearchProvider);
    final settings = ref.watch(schoolSettingsProvider).valueOrNull;

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

    // Category counts (per A1/A2/A) for the segmented chip.
    final categoryCounts = {
      'A1': allBikes.where((b) => b.category == 'A1').length,
      'A2': allBikes.where((b) => b.category == 'A2').length,
      'A': allBikes.where((b) => b.category == 'A').length,
    };

    // Docs (MOT or tax) counts. We take the worst-of-both per bike so
    // a row only counts toward the most urgent bucket it has.
    BikeWarning worstDoc(FleetBike b) {
      final mot = bucketExpiry(b.motExpiresOn,
          warnDays: settings?.motWarnDays ?? 90,
          urgentDays: settings?.motUrgentDays ?? 14);
      final tax = bucketExpiry(b.taxExpiresOn,
          warnDays: settings?.taxWarnDays ?? 30,
          urgentDays: settings?.taxUrgentDays ?? 7);
      // Severity order: expired > urgent > warn > ok > unknown.
      const order = {
        BikeWarning.unknown: 0,
        BikeWarning.ok: 1,
        BikeWarning.dueSoon: 2,
        BikeWarning.dueUrgent: 3,
        BikeWarning.expired: 4,
      };
      return order[mot]! >= order[tax]! ? mot : tax;
    }

    final docsCounts = {
      'warn': allBikes.where((b) => worstDoc(b) == BikeWarning.dueSoon).length,
      'urgent': allBikes.where((b) {
        final w = worstDoc(b);
        return w == BikeWarning.dueUrgent || w == BikeWarning.expired;
      }).length,
      'unknown': allBikes.where((b) => worstDoc(b) == BikeWarning.unknown).length,
    };

    final q = query.trim().toLowerCase();
    final filtered = allBikes.where((b) {
      final statusOK = switch (filter) {
        'ready' => b.status == 'ready',
        'down' => b.status != 'ready',
        _ => true,
      };
      final locOK = locFilter == 'all' || b.currentLocationId == locFilter;
      final catOK = catFilter == 'all' || b.category == catFilter;
      final docsOK = switch (docsFilter) {
        'warn' => worstDoc(b) == BikeWarning.dueSoon,
        'urgent' =>
          worstDoc(b) == BikeWarning.dueUrgent || worstDoc(b) == BikeWarning.expired,
        'unknown' => worstDoc(b) == BikeWarning.unknown,
        _ => true,
      };
      final searchOK = q.isEmpty ||
          b.nickname.toLowerCase().contains(q) ||
          b.make.toLowerCase().contains(q) ||
          b.model.toLowerCase().contains(q) ||
          b.registration.toLowerCase().contains(q);
      return statusOK && locOK && catOK && docsOK && searchOK;
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
            onAdd: () => _showAddBikeSheet(context, ref),
            showCounts: !async.isLoading,
          ),
          const SizedBox(height: 16),
          _SearchField(
            initial: query,
            onChanged: (v) =>
                ref.read(_fleetSearchProvider.notifier).state = v,
          ),
          const SizedBox(height: 10),
          _FilterSeg(
            value: filter,
            counts: (allBikes.length, readyCount, downCount),
            onChanged: (v) =>
                ref.read(_fleetFilterProvider.notifier).state = v,
          ),
          const SizedBox(height: 10),
          _CategoryFilter(
            value: catFilter,
            allCount: allBikes.length,
            counts: categoryCounts,
            onChanged: (v) => ref
                .read(_fleetCategoryFilterProvider.notifier)
                .state = v,
          ),
          const SizedBox(height: 10),
          _DocsFilter(
            value: docsFilter,
            allCount: allBikes.length,
            counts: docsCounts,
            onChanged: (v) =>
                ref.read(_fleetDocsFilterProvider.notifier).state = v,
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
            error: (e, _) => KsEmptyState.error(message: e.toString()),
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
        Expanded(flex: 3, child: _Col('Spec · Mileage')),
        Expanded(flex: 3, child: _Col('MOT / Tax')),
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
          child: InkWell(
            onTap: () => context.go('/admin/fleet/${b.id}'),
            borderRadius: BorderRadius.circular(KsRadius.sm),
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
                      color: KsColors.primary,
                      fontSize: 13.5,
                      decoration: TextDecoration.underline),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right, size: 16, color: KsColors.ink3),
            ]),
          ),
        ),
        Expanded(
          flex: 2,
          child: b.registration.isEmpty
              ? const Text('—',
                  style: TextStyle(color: KsColors.ink3, fontSize: 13))
              : InkWell(
                  onTap: () => openVehicleEnquiry(context, b.registration),
                  borderRadius: BorderRadius.circular(KsRadius.sm),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(
                      child: Text(
                        b.registration,
                        style: ksMono(size: 12.5, weight: FontWeight.w700)
                            .copyWith(
                                color: KsColors.primary,
                                decoration: TextDecoration.underline),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 3),
                    const Icon(Icons.open_in_new,
                        size: 11, color: KsColors.primary),
                  ]),
                ),
        ),
        Expanded(flex: 2, child: _CategoryBadge(category: b.category)),
        Expanded(
          flex: 3,
          child: Text(
            _engineMileageLabel(b),
            style: const TextStyle(color: KsColors.ink2, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(flex: 3, child: _DocsCell(bike: b)),
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

// ===== Chunk 2: MOT/tax/mileage rendering helpers =====

/// Formats the "Spec · Mileage" column: engine/transmission + mileage
/// when known. Empty parts are dropped so a fully-unknown bike just
/// shows '—'.
String _engineMileageLabel(FleetBike b) {
  final parts = <String>[];
  if (b.engineCc > 0) parts.add('${b.engineCc}cc');
  if (b.transmission.isNotEmpty) parts.add(b.transmission);
  if (b.currentMileageMiles > 0) {
    parts.add('${_thousands(b.currentMileageMiles)} mi');
  }
  return parts.isEmpty ? '—' : parts.join(' · ');
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

/// Two compact MOT + Tax pills, colour-coded by the warning bucket.
/// Reads thresholds from the cached schoolSettingsProvider so a
/// change in /admin/settings repaints immediately on this screen.
class _DocsCell extends ConsumerWidget {
  final FleetBike bike;
  const _DocsCell({required this.bike});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(schoolSettingsProvider).valueOrNull;
    final motWarn = s?.motWarnDays ?? 90;
    final motUrgent = s?.motUrgentDays ?? 14;
    final taxWarn = s?.taxWarnDays ?? 30;
    final taxUrgent = s?.taxUrgentDays ?? 7;
    final motStatus = bucketExpiry(bike.motExpiresOn,
        warnDays: motWarn, urgentDays: motUrgent);
    final taxStatus = bucketExpiry(bike.taxExpiresOn,
        warnDays: taxWarn, urgentDays: taxUrgent);
    Future<void> openUpdate() async {
      final result = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: KsColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
        ),
        builder: (_) => _UpdateBikeStateSheet(bike: bike),
      );
      if (result == true) {
        ref.invalidate(fleetProvider);
      }
    }

    return InkWell(
      onTap: openUpdate,
      borderRadius: BorderRadius.circular(KsRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Wrap(spacing: 4, runSpacing: 4, children: [
          _DocPill(label: 'MOT', warning: motStatus, expires: bike.motExpiresOn),
          _DocPill(label: 'Tax', warning: taxStatus, expires: bike.taxExpiresOn),
        ]),
      ),
    );
  }
}

class _DocPill extends StatelessWidget {
  final String label;
  final BikeWarning warning;
  final String expires;
  const _DocPill({
    required this.label,
    required this.warning,
    required this.expires,
  });
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (warning) {
      BikeWarning.unknown => (KsColors.surface3, KsColors.ink3),
      BikeWarning.ok => (KsColors.successTint, KsColors.success),
      BikeWarning.dueSoon => (KsColors.warningTint, KsColors.warning),
      BikeWarning.dueUrgent => (KsColors.dangerTint, KsColors.danger),
      BikeWarning.expired => (KsColors.dangerTint, KsColors.danger),
    };
    final text = warning == BikeWarning.unknown
        ? '$label —'
        : '$label · ${warningLabel(warning, expires: expires)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text(text,
          style: TextStyle(
              color: fg, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}

// ===== Update sheet: MOT, tax, mileage =====

/// Bottom sheet for editing MOT/tax dates + current mileage on a bike.
/// Saves via PUT /bikes/{id} for the dates and POST /bikes/{id}/mileage
/// for the reading. Returns true on save so the caller can refresh.
class _UpdateBikeStateSheet extends ConsumerStatefulWidget {
  final FleetBike bike;
  const _UpdateBikeStateSheet({required this.bike});
  @override
  ConsumerState<_UpdateBikeStateSheet> createState() => _UpdateBikeStateSheetState();
}

class _UpdateBikeStateSheetState extends ConsumerState<_UpdateBikeStateSheet> {
  late DateTime? _mot = DateTime.tryParse(widget.bike.motExpiresOn);
  late DateTime? _tax = DateTime.tryParse(widget.bike.taxExpiresOn);
  late final TextEditingController _miles = TextEditingController(
      text: widget.bike.currentMileageMiles > 0
          ? widget.bike.currentMileageMiles.toString()
          : '');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _miles.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final orig = widget.bike;

      String? motArg;
      final motISO = _mot == null ? '' : _isoDate(_mot!);
      if (motISO != orig.motExpiresOn) motArg = motISO;

      String? taxArg;
      final taxISO = _tax == null ? '' : _isoDate(_tax!);
      if (taxISO != orig.taxExpiresOn) taxArg = taxISO;

      if (motArg != null || taxArg != null) {
        await api.updateBikeState(
          id: orig.id,
          nickname: orig.nickname,
          make: orig.make,
          model: orig.model,
          registration: orig.registration,
          engineCc: orig.engineCc,
          motExpiresOn: motArg,
          taxExpiresOn: taxArg,
        );
      }

      final newMiles = int.tryParse(_miles.text.trim());
      if (newMiles != null && newMiles != orig.currentMileageMiles) {
        await api.recordBikeMileage(id: orig.id, miles: newMiles);
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save.';
      });
    }
  }

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _pick({required bool mot}) async {
    final now = DateTime.now();
    final initial = (mot ? _mot : _tax) ?? now.add(const Duration(days: 90));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() {
      if (mot) {
        _mot = picked;
      } else {
        _tax = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bike;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 18, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('Update ${b.nickname.isEmpty ? "bike" : b.nickname}',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: KsColors.ink)),
            ),
            if (b.registration.isNotEmpty)
              TextButton.icon(
                onPressed: () => openMotHistory(context, b.registration),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('MOT history'),
                style: TextButton.styleFrom(foregroundColor: KsColors.primary),
              ),
          ]),
          const SizedBox(height: 12),

          // MOT date
          Text('MOT expires on',
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700, color: KsColors.ink2, fontSize: 13)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : () => _pick(mot: true),
                icon: const Icon(Icons.calendar_today_outlined, size: 16),
                label: Text(_mot == null ? 'Pick a date' : _isoDate(_mot!)),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                ),
              ),
            ),
            if (_mot != null) ...[
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Clear',
                onPressed: _saving ? null : () => setState(() => _mot = null),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ]),
          const SizedBox(height: 16),

          // Tax date
          Text('Tax expires on',
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w700, color: KsColors.ink2, fontSize: 13)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : () => _pick(mot: false),
                icon: const Icon(Icons.calendar_today_outlined, size: 16),
                label: Text(_tax == null ? 'Pick a date' : _isoDate(_tax!)),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                ),
              ),
            ),
            if (_tax != null) ...[
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Clear',
                onPressed: _saving ? null : () => setState(() => _tax = null),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ]),
          const SizedBox(height: 16),

          // Mileage
          TextField(
            controller: _miles,
            keyboardType: const TextInputType.numberWithOptions(decimal: false),
            decoration: const InputDecoration(
              labelText: 'Current mileage (mi)',
              hintText: 'e.g. 12840',
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: KsColors.dangerTint,
                borderRadius: BorderRadius.circular(KsRadius.md),
              ),
              child: Text(_error!,
                  style: const TextStyle(color: KsColors.danger, fontSize: 13)),
            ),
          ],

          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(KsRadius.md),
                ),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5))
                  : const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}

// ===== Chunk 3: Search + extra filter chips =====

/// Free-text search across nickname, make, model, registration.
/// Stateful so the field keeps its cursor + clear-button affordance
/// without thrashing the autoDispose StateProvider on every keystroke.
class _SearchField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.initial, required this.onChanged});
  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search, size: 20, color: KsColors.ink3),
        hintText: 'Search nickname, make/model, registration…',
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        suffixIcon: _c.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close, size: 18, color: KsColors.ink3),
                onPressed: () {
                  _c.clear();
                  widget.onChanged('');
                  setState(() {});
                },
              ),
      ),
    );
  }
}

/// Shared visual treatment for every filter row on this screen:
/// a `surface2`-tinted pill container with internal buttons that
/// flip to `surface` + shadow when selected. Matches `_FilterSeg`
/// and `_LocationFilter` above — keeps the page's four filter rows
/// looking like one consistent control instead of three styles.
class _SegmentedFilter extends StatelessWidget {
  final String value;
  final List<(String, String)> options; // (key, label)
  final ValueChanged<String> onChanged;
  const _SegmentedFilter({
    required this.value,
    required this.options,
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
      child: Wrap(children: [
        for (final (k, label) in options) _segBtn(k, label),
      ]),
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

class _CategoryFilter extends StatelessWidget {
  final String value;
  final int allCount;
  final Map<String, int> counts;
  final ValueChanged<String> onChanged;
  const _CategoryFilter({
    required this.value,
    required this.allCount,
    required this.counts,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _SegmentedFilter(
      value: value,
      onChanged: onChanged,
      options: [
        ('all', 'All $allCount'),
        ('A1', 'A1 ${counts['A1'] ?? 0}'),
        ('A2', 'A2 ${counts['A2'] ?? 0}'),
        ('A', 'A ${counts['A'] ?? 0}'),
      ],
    );
  }
}

class _DocsFilter extends StatelessWidget {
  final String value;
  final int allCount;
  final Map<String, int> counts;
  final ValueChanged<String> onChanged;
  const _DocsFilter({
    required this.value,
    required this.allCount,
    required this.counts,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _SegmentedFilter(
      value: value,
      onChanged: onChanged,
      options: [
        ('all', 'Docs · All $allCount'),
        ('urgent', 'Urgent ${counts['urgent'] ?? 0}'),
        ('warn', 'Due soon ${counts['warn'] ?? 0}'),
        ('unknown', 'Unknown ${counts['unknown'] ?? 0}'),
      ],
    );
  }
}

// ===== Add-bike sheet =====

class _AddBikeSheet extends ConsumerStatefulWidget {
  const _AddBikeSheet();
  @override
  ConsumerState<_AddBikeSheet> createState() => _AddBikeSheetState();
}

class _AddBikeSheetState extends ConsumerState<_AddBikeSheet> {
  final _nickname = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _registration = TextEditingController();
  final _engineCc = TextEditingController();
  String _category = 'A1';
  String _transmission = 'manual';
  String? _homeLocationId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nickname.dispose();
    _make.dispose();
    _model.dispose();
    _registration.dispose();
    _engineCc.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_homeLocationId == null) {
      setState(() => _error = 'Pick a home location.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await ref.read(apiClientProvider).createBike(
            nickname: _nickname.text.trim(),
            make: _make.text.trim(),
            model: _model.text.trim(),
            registration: _registration.text.trim().toUpperCase(),
            category: _category,
            transmission: _transmission,
            engineCc: int.tryParse(_engineCc.text.trim()) ?? 0,
            homeLocationId: _homeLocationId!,
          );
      if (mounted) Navigator.pop(context, created);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not add bike.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locs = ref.watch(locationsProvider).valueOrNull ?? const [];
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
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
                Text('Add bike',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink)),
                const SizedBox(height: 4),
                const Text(
                  'Status defaults to Ready. Current location starts at the home site — '
                  'logistics will update it after the first session.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12),
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: _nickname,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nickname',
                    hintText: 'e.g. Blueberry',
                  ),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _make,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Make'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _model,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Model'),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _registration,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Registration',
                        hintText: 'e.g. NX24 ABC',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _engineCc,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: false),
                      decoration: const InputDecoration(
                        labelText: 'Engine (cc)',
                        hintText: 'e.g. 125',
                      ),
                    ),
                  ),
                ]),

                const SizedBox(height: 14),
                Text('Category',
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700,
                        color: KsColors.ink,
                        fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final c in const [
                    ('A1', 'A1 (125 cc)'),
                    ('A2', 'A2 (650 cc)'),
                    ('A', 'A (full)'),
                  ])
                    _picker(
                      label: c.$2,
                      selected: _category == c.$1,
                      onTap: () => setState(() => _category = c.$1),
                    ),
                ]),

                const SizedBox(height: 14),
                Text('Transmission',
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700,
                        color: KsColors.ink,
                        fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final t in const [
                    ('manual', 'Manual'),
                    ('auto', 'Auto'),
                  ])
                    _picker(
                      label: t.$2,
                      selected: _transmission == t.$1,
                      onTap: () => setState(() => _transmission = t.$1),
                    ),
                ]),

                const SizedBox(height: 14),
                Text('Home location',
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700,
                        color: KsColors.ink,
                        fontSize: 13)),
                const SizedBox(height: 6),
                if (locs.isEmpty)
                  const Text(
                    'Add a location first under Locations.',
                    style: TextStyle(color: KsColors.ink3, fontSize: 13),
                  )
                else
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final l in locs)
                      _picker(
                        label: l.name,
                        selected: _homeLocationId == l.id,
                        onTap: () => setState(() => _homeLocationId = l.id),
                      ),
                  ]),

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

                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: _saving ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(KsRadius.md),
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5))
                      : const Text('Add bike'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _picker({
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(KsRadius.pill),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? KsColors.primaryTint : KsColors.surface2,
        borderRadius: BorderRadius.circular(KsRadius.pill),
        border: Border.all(
          color: selected
              ? KsColors.primary.withValues(alpha: 0.5)
              : KsColors.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Text(label,
          style: TextStyle(
            color: selected ? KsColors.primaryDeep : KsColors.ink2,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          )),
    ),
  );
}
