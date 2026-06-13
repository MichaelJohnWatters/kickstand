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
        child: Stack(
          children: [
            FlutterMap(
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
                          onTap: () => setState(() => _selected = b),
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
