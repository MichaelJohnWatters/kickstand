import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/tokens.dart';

/// Coloured initials avatar — the design's signature for staff and
/// students. Tone is a hash of the name so two people don't share a
/// colour by accident, but the same person renders consistently across
/// screens.
class KsAvatar extends StatelessWidget {
  final String name;
  final double size;
  final bool ring;
  const KsAvatar({
    required this.name,
    this.size = 40,
    this.ring = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tone = _toneFor(name);
    final fg = HSLColor.fromAHSL(1, tone, 0.55, 0.35).toColor();
    final bg = HSLColor.fromAHSL(1, tone, 0.72, 0.92).toColor();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: ring
            ? Border.all(color: KsColors.surface, width: 2)
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        _initials(name),
        style: GoogleFonts.plusJakartaSans(
          color: fg,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.36,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts[0].isEmpty) return '?';
  final first = parts[0][0];
  final last = parts.length > 1 ? parts.last[0] : '';
  return (first + last).toUpperCase();
}

double _toneFor(String name) {
  if (name.isEmpty) return 277;
  var h = 0;
  for (final r in name.runes) {
    h = (h * 31 + r) & 0x7fffffff;
  }
  // Pick from the full hue wheel but avoid grey-ish neutrals.
  return (h % 360).toDouble();
}
