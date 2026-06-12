// Empty / error state card — the recognisable "card with an icon and
// a sentence" used across admin and instructor surfaces when a list is
// empty or a fetch failed.
//
// Pulled out of admin_signups_screen so other pages can stop showing
// plain "Couldn't load.\n$e" text. Defaults to a neutral grey icon
// background; pass `iconColour` for variant (danger red for errors,
// success green for happy empty states like "All clear").

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/tokens.dart';

class KsEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Color? iconColour;

  /// Optional CTA at the bottom — used by error states for "Try again".
  final String? actionLabel;
  final VoidCallback? onAction;

  const KsEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.iconColour,
    this.actionLabel,
    this.onAction,
  });

  /// Convenience for the very common "couldn't load" surface — same
  /// shape as the manual version but reads better at call sites.
  factory KsEmptyState.error({
    Key? key,
    required String message,
    String title = 'Couldn’t load',
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      KsEmptyState(
        key: key,
        icon: Icons.error_outline,
        iconColour: KsColors.danger,
        title: title,
        message: message,
        actionLabel: actionLabel,
        onAction: onAction,
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 36),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: KsColors.surface3,
              borderRadius: BorderRadius.circular(KsRadius.md),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: iconColour ?? KsColors.ink4, size: 26),
          ),
          const SizedBox(height: 14),
          Text(title,
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: KsColors.ink3, fontSize: 13.5, height: 1.45),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
