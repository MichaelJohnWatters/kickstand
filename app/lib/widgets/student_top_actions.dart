// Bell + avatar cluster that lives in the top-right of every student screen.
// Consistency matters more than cleverness here — students should always
// know where notifications and "sign out" live, no matter which tab
// they're on.

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/providers.dart';
import '../theme/tokens.dart';
import 'notification_bell.dart';

class StudentTopActions extends ConsumerWidget {
  /// Padding from the trailing edge. Defaults match the AppBar's usual
  /// inset; pass 0 when the parent already adds horizontal padding.
  final double trailingPadding;
  const StudentTopActions({super.key, this.trailingPadding = 8});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final initials = _initialsOf(auth.identity?.name ?? '');
    return Padding(
      padding: EdgeInsets.only(right: trailingPadding),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const NotificationBell(),
          const SizedBox(width: 8),
          _StudentAvatar(
            initials: initials,
            onLogout: () =>
                ref.read(authControllerProvider.notifier).logout(),
            onDownloadData: () => _downloadMyData(context, ref),
          ),
        ],
      ),
    );
  }
}

/// Calls /me/data-export, encodes the JSON, and pops a native save
/// dialog (or browser download on web). GDPR Article 20 right of
/// access — kept inside the avatar menu so it's discoverable without
/// adding a top-level "Privacy" screen.
Future<void> _downloadMyData(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final data = await ref.read(apiClientProvider).myDataExport();
    final pretty = const JsonEncoder.withIndent('  ').convert(data);
    final bytes = Uint8List.fromList(utf8.encode(pretty));
    final saved = await FilePicker.platform.saveFile(
      dialogTitle: 'Save my Kickstand data',
      fileName: 'kickstand-data-export.json',
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (!context.mounted) return;
    if (saved == null) return; // user cancelled or browser auto-downloaded.
    messenger.showSnackBar(SnackBar(content: Text('Saved to $saved')));
  } catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
  }
}

class _StudentAvatar extends StatelessWidget {
  final String initials;
  final VoidCallback onLogout;
  final VoidCallback onDownloadData;
  const _StudentAvatar({
    required this.initials,
    required this.onLogout,
    required this.onDownloadData,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      offset: const Offset(0, 48),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KsRadius.md)),
      onSelected: (v) {
        if (v == 'logout') onLogout();
        if (v == 'export') onDownloadData();
      },
      itemBuilder: (_) => const [
        PopupMenuItem<String>(
          value: 'export',
          child: Row(
            children: [
              Icon(Icons.download_outlined, size: 18, color: KsColors.ink2),
              SizedBox(width: 8),
              Text('Download my data'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'logout',
          child: Row(
            children: [
              Icon(Icons.logout, size: 18, color: KsColors.ink2),
              SizedBox(width: 8),
              Text('Sign out'),
            ],
          ),
        ),
      ],
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: KsColors.primaryTint,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(color: KsColors.border),
        ),
        alignment: Alignment.center,
        child: Text(initials,
            style: GoogleFonts.plusJakartaSans(
                color: KsColors.primaryDeep,
                fontWeight: FontWeight.w800,
                fontSize: 14)),
      ),
    );
  }
}

String _initialsOf(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}
