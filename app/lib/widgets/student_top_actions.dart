// Bell + avatar cluster that lives in the top-right of every student screen.
// Consistency matters more than cleverness here — students should always
// know where notifications and "sign out" live, no matter which tab
// they're on.

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
          ),
        ],
      ),
    );
  }
}

class _StudentAvatar extends StatelessWidget {
  final String initials;
  final VoidCallback onLogout;
  const _StudentAvatar({required this.initials, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      offset: const Offset(0, 48),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KsRadius.md)),
      onSelected: (v) {
        if (v == 'logout') onLogout();
      },
      itemBuilder: (_) => const [
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
