// UK gov.uk vehicle-check URLs derived from a bike's registration.
//
// Both pages are public — no API key, no quota. The vehicle enquiry
// page returns both MOT and tax status in one view, so it's the
// primary link from the bike card. The MOT-only page is kept as a
// secondary "view full MOT history" link inside the update sheet
// because it includes manufacturer recalls when checkRecalls=true.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// vehicleenquiry.service.gov.uk — confirms reg → shows tax + MOT
/// expiry + service history + CO2 etc.
Uri vehicleEnquiryUrl(String registration) => Uri.https(
      'vehicleenquiry.service.gov.uk',
      '/ConfirmVehicle',
      {'Vrm': registration.replaceAll(' ', '').toUpperCase()},
    );

/// check-mot.service.gov.uk — MOT history + advisories + manufacturer
/// recalls. Useful from the "Update MOT" sheet.
Uri motHistoryUrl(String registration) => Uri.https(
      'www.check-mot.service.gov.uk',
      '/results',
      {
        'registration': registration.replaceAll(' ', '').toUpperCase(),
        'checkRecalls': 'true',
      },
    );

Future<void> openVehicleEnquiry(BuildContext context, String registration) =>
    _open(context, vehicleEnquiryUrl(registration));

Future<void> openMotHistory(BuildContext context, String registration) =>
    _open(context, motHistoryUrl(registration));

Future<void> _open(BuildContext context, Uri uri) async {
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the link.')),
    );
  }
}
