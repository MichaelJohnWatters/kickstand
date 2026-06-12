import 'package:flutter/material.dart';

/// Course-accent colour resolver. Prefers the school-configured hex
/// (`#RRGGBB`); falls back to a deterministic palette pick from the
/// course code so a brand-new course type still gets a stable colour.
Color courseColour(String code, [String hex = '']) {
  var s = hex.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) {
    final n = int.tryParse(s, radix: 16);
    if (n != null) return Color(0xFF000000 | n);
  }
  if (code.isEmpty) return _palette[0];
  var h = 0;
  for (final r in code.runes) {
    h = (h * 31 + r) & 0x7fffffff;
  }
  return _palette[h % _palette.length];
}

// Same palette as the admin master calendar — keep them in sync so a
// course renders identically on both sides.
const _palette = <Color>[
  Color(0xFF6366F1), // indigo
  Color(0xFF9333EA), // purple
  Color(0xFF0EA5E9), // sky
  Color(0xFF1F9D6B), // green
  Color(0xFFF59E0B), // amber
  Color(0xFFC98A1E), // dark amber
];
