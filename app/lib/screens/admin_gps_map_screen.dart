// Admin Live Map — plots every bike's last-known GPS fix as a marker
// over Northern Ireland. Scheduling/logistics engine never reads GPS
// (plan §7); this is presentation-only. Bikes without a fix surface
// in the off-map "No signal" panel rather than being hidden.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

class AdminGpsMapScreen extends ConsumerWidget {
  const AdminGpsMapScreen({super.key});

  // NI centroid. Fits Belfast / Lisburn / Newry comfortably at zoom 9.
  static const _niCentre = LatLng(54.45, -6.20);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(bikeGpsProvider);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Live map',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: KsColors.ink,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            "Where every bike with a tracker has been spotted last. The "
            "scheduling engine doesn't use GPS — that's still driven by "
            "current_location_id.",
            style: TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: async.when(
              loading: () => const Center(
                  child:
                      CircularProgressIndicator(color: KsColors.primary)),
              error: (e, _) => KsEmptyState.error(message: e.toString()),
              data: (bikes) => _MapBody(bikes: bikes),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapBody extends ConsumerStatefulWidget {
  final List<BikeGPS> bikes;
  const _MapBody({required this.bikes});

  @override
  ConsumerState<_MapBody> createState() => _MapBodyState();
}

class _MapBodyState extends ConsumerState<_MapBody> {
  BikeGPS? _selected;
  // MapController lets us drive zoom/pan programmatically — the
  // +/- buttons, jump-to-location chips, and the sidebar bike list
  // all call into this.
  final _mapController = MapController();
  // Sidebar starts open on wide screens (≥1100 px), closed on
  // narrow ones so the map gets the room. The user can flip it
  // either way from the toggle button.
  bool _sidebarOpen = true;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  /// Selects a bike and flies the camera to its current fix at
  /// zoom 15 (~street detail). Shared between marker taps and
  /// sidebar row taps.
  void _selectAndFly(BikeGPS b) {
    setState(() => _selected = b);
    if (b.hasFix) {
      _mapController.move(LatLng(b.lat!, b.lng!), 15);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracked = widget.bikes.where((b) => b.hasFix).toList();
    final noSignal = widget.bikes.where((b) => !b.hasFix).toList();
    // Trail for the currently-selected bike (last 24h). We render the
    // polyline only when the user has tapped a marker so the map stays
    // calm for at-a-glance scanning. Live snapshot is always the head
    // of the trail — the polyline connects through the historical fixes.
    final trailAsync = _selected == null
        ? null
        : ref.watch(bikeGpsHistoryProvider(_selected!.id));
    final trailPoints = <LatLng>[];
    if (_selected != null && trailAsync != null) {
      // Head: current snapshot from the live list (newest).
      trailPoints.add(LatLng(_selected!.lat!, _selected!.lng!));
      // Tail: historical fixes ordered newest → oldest by the API.
      for (final f in trailAsync.valueOrNull ?? const <GpsFix>[]) {
        trailPoints.add(LatLng(f.lat, f.lng));
      }
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: KsColors.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_sidebarOpen)
              _FleetSidebar(
                bikes: widget.bikes,
                selectedId: _selected?.id,
                onSelect: _selectAndFly,
                onClose: () => setState(() => _sidebarOpen = false),
              ),
            Expanded(
              child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: const MapOptions(
                initialCenter: AdminGpsMapScreen._niCentre,
                initialZoom: 9,
                minZoom: 6,
                maxZoom: 18,
                interactionOptions:
                    InteractionOptions(flags: InteractiveFlag.all),
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'kickstand.app',
                  maxNativeZoom: 19,
                ),
                if (trailPoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: trailPoints,
                        color: _liveStatusColour(_selected!.liveStatus)
                            .withValues(alpha: 0.65),
                        strokeWidth: 3,
                      ),
                    ],
                  ),
                if (_selected != null && trailAsync != null)
                  MarkerLayer(
                    markers: [
                      for (final f in trailAsync.valueOrNull ?? const <GpsFix>[])
                        Marker(
                          point: LatLng(f.lat, f.lng),
                          width: 10,
                          height: 10,
                          child: _TrailDot(
                              colour:
                                  _liveStatusColour(_selected!.liveStatus)),
                        ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    for (final b in tracked)
                      Marker(
                        point: LatLng(b.lat!, b.lng!),
                        width: 36,
                        height: 36,
                        child: _BikeMarker(
                          bike: b,
                          onTap: () => _selectAndFly(b),
                        ),
                      ),
                  ],
                ),
                RichAttributionWidget(
                  attributions: const [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
            if (noSignal.isNotEmpty)
              Positioned(
                left: 16,
                bottom: 16,
                child: _NoSignalPanel(bikes: noSignal),
              ),
            if (_selected != null)
              Positioned(
                top: 16,
                right: 16,
                child: _SelectedBikeCard(
                  bike: _selected!,
                  trail: trailAsync,
                  onClose: () => setState(() => _selected = null),
                ),
              ),
            // Zoom +/- + reset controls in the bottom-right. Sit
            // separate from the OSM attribution which docks bottom-
            // left of the FlutterMap by default.
            Positioned(
              right: 16,
              bottom: 16,
              child: _MapControls(
                onZoomIn: () => _mapController.move(
                    _mapController.camera.center,
                    (_mapController.camera.zoom + 1).clamp(6, 18)),
                onZoomOut: () => _mapController.move(
                    _mapController.camera.center,
                    (_mapController.camera.zoom - 1).clamp(6, 18)),
                onReset: () => _mapController.move(
                    AdminGpsMapScreen._niCentre, 9),
              ),
            ),
            // Jump-to-location chips. Pulls every geocoded site from
            // /locations and flies the camera there on tap. Hidden
            // when no site has coords yet (graceful degrade).
            Positioned(
              left: 16,
              top: 16,
              child: _JumpToLocationBar(
                onJump: (lat, lng) =>
                    _mapController.move(LatLng(lat, lng), 13),
              ),
            ),
            // Reopen-sidebar tab — only visible when the sidebar is
            // collapsed. Sits flush against the left edge so it
            // reads as "pull the panel back out."
            if (!_sidebarOpen)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _SidebarReopenTab(
                    onOpen: () => setState(() => _sidebarOpen = true),
                  ),
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
}

/// Tiny solid dot for each historical fix on the trail.
class _TrailDot extends StatelessWidget {
  final Color colour;
  const _TrailDot({required this.colour});
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colour,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
    );
  }
}

class _BikeMarker extends StatelessWidget {
  final BikeGPS bike;
  final VoidCallback onTap;
  const _BikeMarker({required this.bike, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colour = _liveStatusColour(bike.liveStatus);
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: bike.nickname.isEmpty ? bike.id : bike.nickname,
        child: Container(
          decoration: BoxDecoration(
            color: colour,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stacked +/-/reset buttons in the bottom-right of the map.
/// `onReset` re-centres the map on the NI centroid at zoom 9, the
/// initial state. Keyboard-accessible too — Material's InkWell + the
/// Tooltip make it obvious what each button does.
class _MapControls extends StatelessWidget {
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  const _MapControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: KsColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ControlButton(
              icon: Icons.add, tooltip: 'Zoom in', onTap: onZoomIn),
          const Divider(height: 1, color: KsColors.border),
          _ControlButton(
              icon: Icons.remove, tooltip: 'Zoom out', onTap: onZoomOut),
          const Divider(height: 1, color: KsColors.border),
          _ControlButton(
              icon: Icons.center_focus_strong_outlined,
              tooltip: 'Reset view',
              onTap: onReset),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _ControlButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 20, color: KsColors.ink2),
        ),
      ),
    );
  }
}

/// Row of chips along the top-left of the map — one per geocoded
/// site. Tapping a chip flies the camera to that site at zoom 13
/// (~city-block detail). Watches `locationsProvider` and filters to
/// rows with coords; renders nothing when no site has coords yet.
class _JumpToLocationBar extends ConsumerWidget {
  final void Function(double lat, double lng) onJump;
  const _JumpToLocationBar({required this.onJump});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locs = ref.watch(locationsProvider).valueOrNull ?? const [];
    final geocoded = locs.where((l) => l.hasCoords).toList();
    if (geocoded.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.pill),
        border: Border.all(color: KsColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child:
              Icon(Icons.place_outlined, size: 16, color: KsColors.ink3),
        ),
        for (final l in geocoded)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: InkWell(
              onTap: () => onJump(l.lat!, l.lng!),
              borderRadius: BorderRadius.circular(KsRadius.pill),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: KsColors.surface2,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                  border: Border.all(color: KsColors.border),
                ),
                child: Text(
                  l.name,
                  style: const TextStyle(
                    color: KsColors.ink2,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Fleet sidebar: a scrollable list of every bike, grouped by live
/// status. Tap a row → fly camera to the bike + open its detail card.
/// "No signal" bikes are listed but greyed out — no jump-to since we
/// don't know where they are.
class _FleetSidebar extends StatelessWidget {
  final List<BikeGPS> bikes;
  final String? selectedId;
  final void Function(BikeGPS) onSelect;
  final VoidCallback onClose;
  const _FleetSidebar({
    required this.bikes,
    required this.selectedId,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    // Group by live status, then alphabetise within group. The
    // visible order is in-session first (managers care most), then
    // available (ready to dispatch), then attention/offline, then
    // no-signal at the bottom.
    final groups = <(String, String, List<BikeGPS>)>[
      ('in_session', 'In session', _filter(bikes, 'in_session', true)),
      ('available', 'Available', _filter(bikes, 'available', true)),
      ('needs_attention', 'Needs attention',
          _filter(bikes, 'needs_attention', true)),
      ('offline', 'Offline', _filter(bikes, 'offline', true)),
      ('no_signal', 'No signal', _filter(bikes, '', false)),
    ];
    final totalShown = groups.fold(0, (n, g) => n + g.$3.length);
    return SizedBox(
      width: 280,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: KsColors.surface,
          border: Border(right: BorderSide(color: KsColors.border)),
        ),
        child: Column(
          children: [
            // Header strip with bike count + collapse button.
            Container(
              padding:
                  const EdgeInsets.fromLTRB(14, 12, 8, 12),
              decoration: const BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: KsColors.border)),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Fleet',
                          style: GoogleFonts.plusJakartaSans(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: KsColors.ink)),
                      Text('$totalShown bikes',
                          style: const TextStyle(
                              color: KsColors.ink3, fontSize: 11)),
                    ],
                  ),
                ),
                Tooltip(
                  message: 'Collapse sidebar',
                  child: InkWell(
                    onTap: onClose,
                    borderRadius: BorderRadius.circular(20),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.chevron_left,
                          size: 20, color: KsColors.ink3),
                    ),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  for (final g in groups)
                    if (g.$3.isNotEmpty) ...[
                      _GroupHeader(label: g.$2, count: g.$3.length),
                      for (final b in g.$3)
                        _BikeRow(
                          bike: b,
                          selected: selectedId == b.id,
                          onTap: () => onSelect(b),
                        ),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<BikeGPS> _filter(
      List<BikeGPS> bikes, String status, bool hasFix) {
    final out = bikes.where((b) {
      if (hasFix && !b.hasFix) return false;
      if (!hasFix && b.hasFix) return false;
      if (status.isEmpty) return true;
      return b.liveStatus == status;
    }).toList();
    out.sort((a, b) {
      final an = a.nickname.isEmpty ? a.id : a.nickname;
      final bn = b.nickname.isEmpty ? b.id : b.nickname;
      return an.toLowerCase().compareTo(bn.toLowerCase());
    });
    return out;
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  final int count;
  const _GroupHeader({required this.label, required this.count});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Text('${label.toUpperCase()} · $count',
          style: GoogleFonts.plusJakartaSans(
              color: KsColors.ink3,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4)),
    );
  }
}

class _BikeRow extends StatelessWidget {
  final BikeGPS bike;
  final bool selected;
  final VoidCallback onTap;
  const _BikeRow({
    required this.bike,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colour = _liveStatusColour(bike.liveStatus);
    final name = bike.nickname.isEmpty ? bike.id : bike.nickname;
    final canJump = bike.hasFix;
    return InkWell(
      onTap: canJump ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? KsColors.primaryTint : null,
          border: Border(
            left: BorderSide(
              color: selected ? KsColors.primary : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: canJump ? colour : KsColors.ink4,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                      color: canJump ? KsColors.ink : KsColors.ink3,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    )),
                if (bike.registration.isNotEmpty)
                  Text(bike.registration,
                      style: GoogleFonts.spaceMono(
                          color: KsColors.ink3, fontSize: 11)),
              ],
            ),
          ),
          if (canJump)
            Text(_shortLastSeen(bike.lastSeenAt),
                style: const TextStyle(
                    color: KsColors.ink3, fontSize: 11)),
        ]),
      ),
    );
  }
}

/// Slim vertical tab that re-opens the sidebar when it's collapsed.
/// Sits flush against the left edge of the map; the chevron-right
/// glyph hints "expand back out."
class _SidebarReopenTab extends StatelessWidget {
  final VoidCallback onOpen;
  const _SidebarReopenTab({required this.onOpen});
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Show fleet sidebar',
      child: Material(
        color: KsColors.surface,
        elevation: 2,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topRight: Radius.circular(10),
            bottomRight: Radius.circular(10),
          ),
        ),
        child: InkWell(
          onTap: onOpen,
          child: Container(
            width: 24,
            height: 72,
            decoration: BoxDecoration(
              border: Border.all(color: KsColors.border),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(10),
                bottomRight: Radius.circular(10),
              ),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.chevron_right,
                size: 20, color: KsColors.ink3),
          ),
        ),
      ),
    );
  }
}

String _shortLastSeen(String iso) {
  if (iso.isEmpty) return '';
  final at = DateTime.tryParse(iso);
  if (at == null) return '';
  final delta = DateTime.now().toUtc().difference(at.toUtc());
  if (delta.inMinutes < 1) return 'now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m';
  if (delta.inHours < 24) return '${delta.inHours}h';
  if (delta.inDays < 7) return '${delta.inDays}d';
  return '>1w';
}

class _NoSignalPanel extends StatelessWidget {
  final List<BikeGPS> bikes;
  const _NoSignalPanel({required this.bikes});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            const Icon(Icons.signal_wifi_off, size: 16, color: KsColors.ink3),
            const SizedBox(width: 6),
            Text('No signal · ${bikes.length}',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w700,
                    color: KsColors.ink,
                    fontSize: 13)),
          ]),
          const SizedBox(height: 8),
          for (final b in bikes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                b.nickname.isEmpty ? b.id : b.nickname,
                style:
                    const TextStyle(color: KsColors.ink2, fontSize: 12),
              ),
            ),
          const SizedBox(height: 6),
          const Text(
            'Wire a tracker via POST /bikes/{id}/gps to plot these.',
            style: TextStyle(color: KsColors.ink3, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _SelectedBikeCard extends StatelessWidget {
  final BikeGPS bike;
  final AsyncValue<List<GpsFix>>? trail;
  final VoidCallback onClose;
  const _SelectedBikeCard({
    required this.bike,
    required this.trail,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KsColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                bike.nickname.isEmpty ? bike.id : bike.nickname,
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w700,
                    color: KsColors.ink,
                    fontSize: 16),
              ),
            ),
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(20),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 18, color: KsColors.ink3),
              ),
            ),
          ]),
          if (bike.registration.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                bike.registration,
                style: GoogleFonts.spaceMono(
                    color: KsColors.ink2, fontSize: 12),
              ),
            ),
          const SizedBox(height: 10),
          _StatusPill(liveStatus: bike.liveStatus),
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.place_outlined, size: 14, color: KsColors.ink3),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                bike.currentLocationName.isEmpty
                    ? bike.currentLocationId
                    : bike.currentLocationName,
                style: const TextStyle(color: KsColors.ink2, fontSize: 12),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.access_time, size: 14, color: KsColors.ink3),
            const SizedBox(width: 4),
            Text(
              _formatLastSeen(bike.lastSeenAt),
              style: const TextStyle(color: KsColors.ink2, fontSize: 12),
            ),
          ]),
          const SizedBox(height: 6),
          _TrailLine(trail: trail),
        ],
      ),
    );
  }
}

/// One-line summary of the breadcrumb trail in the selected-bike card
/// — loading spinner / "N fixes (last 24h)" / "No prior fixes" / error.
class _TrailLine extends StatelessWidget {
  final AsyncValue<List<GpsFix>>? trail;
  const _TrailLine({required this.trail});
  @override
  Widget build(BuildContext context) {
    final t = trail;
    if (t == null) return const SizedBox.shrink();
    return Row(children: [
      const Icon(Icons.timeline, size: 14, color: KsColors.ink3),
      const SizedBox(width: 4),
      Expanded(
        child: t.when(
          loading: () => const Text('Loading trail…',
              style: TextStyle(color: KsColors.ink3, fontSize: 12)),
          error: (e, _) => const Text('Couldn’t load trail',
              style: TextStyle(color: KsColors.danger, fontSize: 12)),
          data: (fixes) {
            if (fixes.isEmpty) {
              return const Text('No prior fixes in the last 24h',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12));
            }
            final oldest = fixes.last.at;
            final delta = DateTime.now().toUtc().difference(oldest);
            final spanLabel = delta.inHours >= 1
                ? '${delta.inHours} h'
                : '${delta.inMinutes} min';
            return Text(
              'Trail · ${fixes.length} fixes over $spanLabel',
              style: const TextStyle(color: KsColors.ink2, fontSize: 12),
            );
          },
        ),
      ),
    ]);
  }
}

class _StatusPill extends StatelessWidget {
  final String liveStatus;
  const _StatusPill({required this.liveStatus});

  @override
  Widget build(BuildContext context) {
    final colour = _liveStatusColour(liveStatus);
    final label = _liveStatusLabel(liveStatus);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colour.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colour,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}

Color _liveStatusColour(String s) {
  switch (s) {
    case 'in_session':
      return KsColors.primary;
    case 'offline':
      return KsColors.danger;
    case 'needs_attention':
      return KsColors.warning;
    case 'available':
    default:
      return KsColors.success;
  }
}

String _liveStatusLabel(String s) {
  switch (s) {
    case 'in_session':
      return 'In session';
    case 'offline':
      return 'Offline';
    case 'needs_attention':
      return 'Needs attention';
    case 'available':
    default:
      return 'Available';
  }
}

String _formatLastSeen(String iso) {
  if (iso.isEmpty) return 'Never seen';
  final at = DateTime.tryParse(iso);
  if (at == null) return 'Never seen';
  final delta = DateTime.now().toUtc().difference(at.toUtc());
  if (delta.inMinutes < 1) return 'Just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) return '${delta.inHours} h ago';
  if (delta.inDays < 7) return '${delta.inDays} d ago';
  return 'Over a week ago';
}
