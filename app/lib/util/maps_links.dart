// Helpers for opening a query (address, place name, lat/lng) in Google
// Maps in the user's default browser/app. Pure URL composition — no
// Google Maps API key, no embed, no quota cost.
//
// Used by the locations admin screen today, with student/instructor
// session screens to follow.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Builds the public-facing Google Maps search URL for the given
/// free-form query (typically a street address or place name). Falls
/// back to a generic Maps URL on empty input so the caller can still
/// open Maps and pan.
Uri googleMapsSearchUrl(String query) {
  final q = query.trim();
  if (q.isEmpty) {
    return Uri.parse('https://www.google.com/maps');
  }
  return Uri.https('www.google.com', '/maps/search/', {
    'api': '1',
    'query': q,
  });
}

/// Open the given query in Google Maps. Returns true on success; on
/// failure shows a SnackBar — the typical reason is a desktop env
/// with no browser configured, which is rare on macOS / a dev laptop.
Future<bool> openInGoogleMaps(BuildContext context, String query) async {
  final uri = googleMapsSearchUrl(query);
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open Maps.')),
    );
  }
  return ok;
}
