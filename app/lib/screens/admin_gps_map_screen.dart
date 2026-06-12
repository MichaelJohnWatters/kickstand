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

class _MapBody extends StatefulWidget {
  final List<BikeGPS> bikes;
  const _MapBody({required this.bikes});

  @override
  State<_MapBody> createState() => _MapBodyState();
}

class _MapBodyState extends State<_MapBody> {
  BikeGPS? _selected;

  @override
  Widget build(BuildContext context) {
    final tracked = widget.bikes.where((b) => b.hasFix).toList();
    final noSignal = widget.bikes.where((b) => !b.hasFix).toList();
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
                  onClose: () => setState(() => _selected = null),
                ),
              ),
          ],
        ),
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
  final VoidCallback onClose;
  const _SelectedBikeCard({required this.bike, required this.onClose});

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
        ],
      ),
    );
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
