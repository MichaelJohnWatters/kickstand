// Admin Locations + travel-time matrix.
//
// Layout mirrors design_handoff_kickstand/app/admin.jsx Locations:
//   - Header: "Locations" + "Add site" action
//   - 3-column grid of site cards (striped "map placeholder" header with
//     pin badge + small edit/delete affordances; body shows name/pad/bike count)
//   - Section label "Travel-time matrix"
//   - Matrix card with a route-icon info banner, the matrix table using short
//     labels, and a "Setup buffer" footer row.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../state/school.dart';
import '../theme/tokens.dart';

class AdminLocationsScreen extends ConsumerWidget {
  const AdminLocationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locationsAsync = ref.watch(locationsProvider);
    final travelAsync = ref.watch(travelTimesProvider);
    final settings = ref.watch(schoolSettingsProvider).valueOrNull;
    final fleetAsync = ref.watch(fleetProvider);

    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async {
        ref.invalidate(locationsProvider);
        ref.invalidate(travelTimesProvider);
      },
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Locations',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: KsColors.ink,
                          letterSpacing: -0.6)),
                  const SizedBox(height: 4),
                  const Text(
                    'Your training sites.',
                    style: TextStyle(color: KsColors.ink3, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: () => _showLocationSheet(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add site'),
            ),
          ]),
          const SizedBox(height: 18),

          locationsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => Text('Couldn’t load.\n$e'),
            data: (locations) {
              if (locations.isEmpty) {
                return _empty('No locations yet. Add the first one to start scheduling.');
              }
              final fleet = fleetAsync.valueOrNull ?? const [];
              return Column(children: [
                _LocationsGrid(locations: locations, fleet: fleet),
                const SizedBox(height: 26),
                if (locations.length >= 2) ...[
                  const _SectionLabel('Travel-time matrix'),
                  const SizedBox(height: 8),
                  travelAsync.when(
                    loading: () => const SizedBox(
                        height: 100, child: Center(child: CircularProgressIndicator(color: KsColors.primary))),
                    error: (e, _) => Text('Couldn’t load travel times.\n$e'),
                    data: (rows) => _TravelMatrix(
                      locations: locations,
                      times: rows,
                      bufferMinutes: settings?.travelBufferMinutes ?? 15,
                    ),
                  ),
                ],
              ]);
            },
          ),
        ],
      ),
    );
  }

  Widget _empty(String message) => Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: KsColors.border),
        ),
        child: Column(children: [
          const Icon(Icons.place_outlined, size: 48, color: KsColors.ink4),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center,
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 14, fontWeight: FontWeight.w600, color: KsColors.ink2)),
        ]),
      );
}

// ===== Section label (matches the design's SectionLabel pattern) =====

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 2, 2, 6),
        child: Text(label.toUpperCase(),
            style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: KsColors.ink3,
                letterSpacing: 0.5)),
      );
}

// ===== Locations grid =====

class _LocationsGrid extends StatelessWidget {
  final List<LocationLite> locations;
  final List<FleetBike> fleet;
  const _LocationsGrid({required this.locations, required this.fleet});
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final available = c.maxWidth.isFinite ? c.maxWidth : 900.0;
      final cols = available >= 1100 ? 3 : available >= 700 ? 2 : 1;
      final w = ((available - (cols - 1) * 14) / cols).clamp(220.0, 600.0);
      return Wrap(
        spacing: 14,
        runSpacing: 14,
        children: locations.map((l) {
          final bikeCount = fleet.where((b) => b.currentLocationId == l.id).length;
          return SizedBox(
            width: w,
            child: _LocationCard(location: l, bikeCount: bikeCount),
          );
        }).toList(),
      );
    });
  }
}

class _LocationCard extends ConsumerStatefulWidget {
  final LocationLite location;
  final int bikeCount;
  const _LocationCard({required this.location, required this.bikeCount});
  @override
  ConsumerState<_LocationCard> createState() => _LocationCardState();
}

class _LocationCardState extends ConsumerState<_LocationCard> {
  bool _deleting = false;

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this location?'),
        content: Text(
            '${widget.location.name} will be removed if no sessions, bikes or travel times reference it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: KsColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _deleting = true);
    try {
      await ref.read(apiClientProvider).deleteLocation(widget.location.id);
      ref.invalidate(locationsProvider);
      ref.invalidate(travelTimesProvider);
    } on ApiException catch (e) {
      if (mounted) {
        final msg = e.code == 'in_use'
            ? 'Can’t delete — still referenced by sessions or bikes.'
            : e.message;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(msg),
            backgroundColor: KsColors.danger,
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Error: $e'),
            backgroundColor: KsColors.danger,
            behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.location;
    return Container(
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Map placeholder — striped diagonal with pin badge top-left and
          // small edit/delete affordances top-right.
          SizedBox(
            height: 92,
            child: Stack(children: [
              const Positioned.fill(
                child: CustomPaint(painter: _DiagonalStripesPainter()),
              ),
              const Positioned.fill(
                child: Center(
                  child: Text('site map placeholder',
                      style: TextStyle(
                          color: KsColors.ink4,
                          fontSize: 11,
                          fontFamily: 'monospace',
                          letterSpacing: 0.2)),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: KsColors.primary,
                    borderRadius: BorderRadius.circular(KsRadius.md),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.place, color: Colors.white, size: 19),
                ),
              ),
              Positioned(
                top: 10,
                right: 8,
                child: Row(children: [
                  _IconChip(
                    icon: Icons.edit_outlined,
                    tooltip: 'Edit',
                    onTap: () => _showLocationSheet(context, ref, existing: l),
                  ),
                  const SizedBox(width: 4),
                  _IconChip(
                    icon: Icons.delete_outline,
                    tooltip: 'Delete',
                    danger: true,
                    busy: _deleting,
                    onTap: _deleting ? null : _delete,
                  ),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.name,
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink,
                        fontSize: 16)),
                if (l.address.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(l.address,
                      style: const TextStyle(color: KsColors.ink3, fontSize: 12.5)),
                ],
                const SizedBox(height: 12),
                Row(children: [
                  const Icon(Icons.two_wheeler, size: 15, color: KsColors.ink2),
                  const SizedBox(width: 5),
                  Text('${widget.bikeCount} bike${widget.bikeCount == 1 ? '' : 's'}',
                      style: const TextStyle(
                          color: KsColors.ink2,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IconChip extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final bool danger;
  final bool busy;
  const _IconChip({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.danger = false,
    this.busy = false,
  });
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KsRadius.sm),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: KsColors.surface.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(KsRadius.sm),
            border: Border.all(color: KsColors.border),
          ),
          alignment: Alignment.center,
          child: busy
              ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, size: 14, color: danger ? KsColors.danger : KsColors.ink2),
        ),
      ),
    );
  }
}

/// Repeating 45° stripes for the "site map placeholder" header. Matches
/// the JSX `repeating-linear-gradient(45deg, surface-3 0 10px, surface-2 10px 20px)`.
class _DiagonalStripesPainter extends CustomPainter {
  const _DiagonalStripesPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()..color = KsColors.surface2;
    canvas.drawRect(Offset.zero & size, base);
    final stripe = Paint()..color = KsColors.surface3;
    const double step = 20;
    final diag = size.width + size.height;
    for (double x = -size.height; x < diag; x += step) {
      // 10px wide stripe per 20px cycle, sloping at 45°.
      final path = Path()
        ..moveTo(x, 0)
        ..lineTo(x + 10, 0)
        ..lineTo(x + 10 + size.height, size.height)
        ..lineTo(x + size.height, size.height)
        ..close();
      canvas.drawPath(path, stripe);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ===== Travel-time matrix =====

class _TravelMatrix extends ConsumerWidget {
  final List<LocationLite> locations;
  final List<TravelTime> times;
  final int bufferMinutes;
  const _TravelMatrix({
    required this.locations,
    required this.times,
    required this.bufferMinutes,
  });

  String _shortLabel(LocationLite l) {
    // Use the first whitespace-delimited word of the site name as the
    // short label (matches the design's "Belfast" rather than "Belfast
    // (Boucher Rd)"). Falls back to the full name if there's no space.
    final parts = l.name.trim().split(RegExp(r'\s+'));
    return parts.isEmpty ? l.name : parts.first;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final byPair = <String, int>{
      for (final t in times) '${t.fromLocationId}|${t.toLocationId}': t.minutes,
    };
    final headerLabels = {for (final l in locations) l.id: _shortLabel(l)};
    return Container(
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Info banner with route icon (matches the JSX header note).
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: KsColors.border)),
            ),
            child: Row(children: [
              const Icon(Icons.route_outlined, color: KsColors.primary, size: 16),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Approx minutes between sites — powers tight-travel warnings on the calendar and bike-logistics feasibility. Manager’s common-sense call; non-blocking.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12.5),
                ),
              ),
            ]),
          ),
          // Matrix
          Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTableTheme(
                data: const DataTableThemeData(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const SizedBox(width: 60),
                      for (final col in locations)
                        SizedBox(
                          width: 72,
                          child: Center(
                            child: Text(headerLabels[col.id] ?? col.name,
                                style: const TextStyle(
                                    color: KsColors.ink3,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12)),
                          ),
                        ),
                    ]),
                    const SizedBox(height: 4),
                    for (final row in locations)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(children: [
                          SizedBox(
                            width: 60,
                            child: Text(headerLabels[row.id] ?? row.name,
                                style: const TextStyle(
                                    color: KsColors.ink2,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12.5)),
                          ),
                          for (final col in locations)
                            SizedBox(
                              width: 72,
                              child: row.id == col.id
                                  ? const _SelfCell()
                                  : _MatrixCell(
                                      fromId: row.id,
                                      toId: col.id,
                                      minutes: byPair['${row.id}|${col.id}'],
                                    ),
                            ),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Setup-buffer footer row
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: KsColors.border)),
            ),
            child: _SetupBufferRow(bufferMinutes: bufferMinutes),
          ),
        ],
      ),
    );
  }
}

class _SelfCell extends StatelessWidget {
  const _SelfCell();
  @override
  Widget build(BuildContext context) => Container(
        height: 36,
        margin: const EdgeInsets.all(3),
        alignment: Alignment.center,
        child: const Text('—', style: TextStyle(color: KsColors.ink4)),
      );
}

class _MatrixCell extends ConsumerStatefulWidget {
  final String fromId;
  final String toId;
  final int? minutes;
  const _MatrixCell({required this.fromId, required this.toId, required this.minutes});
  @override
  ConsumerState<_MatrixCell> createState() => _MatrixCellState();
}

class _MatrixCellState extends ConsumerState<_MatrixCell> {
  bool _editing = false;
  late TextEditingController _ctrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.minutes == null ? '' : '${widget.minutes}');
  }

  @override
  void didUpdateWidget(covariant _MatrixCell old) {
    super.didUpdateWidget(old);
    if (!_editing && widget.minutes != old.minutes) {
      _ctrl.text = widget.minutes == null ? '' : '${widget.minutes}';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final v = int.tryParse(_ctrl.text.trim());
    if (v == null || v < 0) {
      setState(() => _editing = false);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).setTravelTime(
            fromLocationId: widget.fromId,
            toLocationId: widget.toId,
            minutes: v,
          );
      ref.invalidate(travelTimesProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not save: $e'),
            backgroundColor: KsColors.danger,
            behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) {
        setState(() {
          _editing = false;
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return Container(
        height: 36,
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: KsColors.primaryTint,
          borderRadius: BorderRadius.circular(8),
        ),
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
              isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero),
          onSubmitted: (_) => _save(),
          onTapOutside: (_) => _save(),
        ),
      );
    }
    return InkWell(
      onTap: _saving ? null : () => setState(() => _editing = true),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 36,
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: KsColors.surface2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: KsColors.border),
        ),
        alignment: Alignment.center,
        child: _saving
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(
                widget.minutes == null ? '·' : '${widget.minutes}m',
                style: TextStyle(
                  color: widget.minutes == null ? KsColors.ink4 : KsColors.ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
      ),
    );
  }
}

class _SetupBufferRow extends ConsumerStatefulWidget {
  final int bufferMinutes;
  const _SetupBufferRow({required this.bufferMinutes});
  @override
  ConsumerState<_SetupBufferRow> createState() => _SetupBufferRowState();
}

class _SetupBufferRowState extends ConsumerState<_SetupBufferRow> {
  bool _editing = false;
  late final TextEditingController _ctrl =
      TextEditingController(text: '${widget.bufferMinutes}');
  bool _saving = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final v = int.tryParse(_ctrl.text.trim());
    if (v == null || v < 0) {
      setState(() => _editing = false);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).updateSchoolSettings(travelBufferMinutes: v);
      ref.invalidate(schoolSettingsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not save: $e'),
            backgroundColor: KsColors.danger,
            behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) {
        setState(() {
          _editing = false;
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      children: [
        const Text('Setup buffer',
            style: TextStyle(
                color: KsColors.ink2, fontWeight: FontWeight.w700, fontSize: 13)),
        if (_editing)
          SizedBox(
            width: 80,
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(suffixText: 'm', isDense: true),
              onSubmitted: (_) => _save(),
              onTapOutside: (_) => _save(),
            ),
          )
        else
          InkWell(
            onTap: _saving ? null : () => setState(() => _editing = true),
            borderRadius: BorderRadius.circular(KsRadius.pill),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
              decoration: BoxDecoration(
                color: KsColors.primaryTint,
                borderRadius: BorderRadius.circular(KsRadius.pill),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('${widget.bufferMinutes} min',
                      style: const TextStyle(
                          color: KsColors.primaryDeep,
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5)),
            ),
          ),
        const Text(
          'added to drive time for parking/setup before flagging a gap as too tight.',
          style: TextStyle(color: KsColors.ink4, fontSize: 12.5),
        ),
      ],
    );
  }
}

// ----- Add/Edit location sheet -----

Future<void> _showLocationSheet(BuildContext context, WidgetRef ref,
    {LocationLite? existing}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _LocationSheet(existing: existing),
  );
}

class _LocationSheet extends ConsumerStatefulWidget {
  final LocationLite? existing;
  const _LocationSheet({this.existing});
  @override
  ConsumerState<_LocationSheet> createState() => _LocationSheetState();
}

class _LocationSheetState extends ConsumerState<_LocationSheet> {
  late TextEditingController _name;
  late TextEditingController _address;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _address = TextEditingController(text: widget.existing?.address ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Name required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      if (widget.existing == null) {
        await api.createLocation(name: _name.text.trim(), address: _address.text.trim());
      } else {
        await api.updateLocation(
            id: widget.existing!.id,
            name: _name.text.trim(),
            address: _address.text.trim());
      }
      ref.invalidate(locationsProvider);
      // Location names denormalise into fleet / logistics / disruption rows.
      ref.invalidate(fleetProvider);
      ref.invalidate(logisticsForDateProvider);
      ref.invalidate(openDisruptionsProvider);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not save.';
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
                  height: 4, width: 36,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: KsColors.border2,
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                  ),
                ),
              ),
              Text(widget.existing == null ? 'Add training site' : 'Edit site',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 18, fontWeight: FontWeight.w800, color: KsColors.ink)),
              const SizedBox(height: 16),
              TextField(controller: _name, decoration: const InputDecoration(labelText: 'Site name'), autofocus: true),
              const SizedBox(height: 10),
              TextField(controller: _address, decoration: const InputDecoration(labelText: 'Training pad / address (optional)')),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: KsColors.dangerTint,
                    borderRadius: BorderRadius.circular(KsRadius.md),
                  ),
                  child: Text(_error!, style: const TextStyle(color: KsColors.danger)),
                ),
              ],
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                    : Text(widget.existing == null ? 'Add site' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
