// Design tokens — colours, typography, radii, shadows.
//
// Source of truth is design_handoff_kickstand/app/tokens.css. The CSS uses
// oklch; we approximate to hex per the handoff README's table. Keep these
// in sync with any future tokens.css updates.

import 'package:flutter/material.dart';

class KsColors {
  // App backgrounds
  static const bg = Color(0xFFF3F4F7);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFFAFBFC);
  static const surface3 = Color(0xFFEEF0F4);

  // Borders
  static const border = Color(0xFFE4E6EC);
  static const border2 = Color(0xFFD2D5DF);

  // Ink scale (text)
  static const ink = Color(0xFF2C2B46);
  static const ink2 = Color(0xFF5D5C77);
  static const ink3 = Color(0xFF8786A0);
  static const ink4 = Color(0xFFAAA9BD);

  // Brand
  static const primary = Color(0xFF6366F1);
  static const primaryDeep = Color(0xFF4338CA);
  static const primaryTint = Color(0xFFECECFB);

  // Semantic
  static const success = Color(0xFF1F9D6B);
  static const successTint = Color(0xFFE6F4EE);
  static const warning = Color(0xFFC98A1E);
  static const warningTint = Color(0xFFFCF1DC);
  static const danger = Color(0xFFD64242);
  static const dangerTint = Color(0xFFFBE5E5);
}

class KsRadius {
  static const xs = 8.0;
  static const sm = 11.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const xl = 28.0;
  static const pill = 999.0;
}

class KsSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

class KsShadows {
  // Subtle card
  static const sh1 = [
    BoxShadow(color: Color(0x0F1E1B4B), offset: Offset(0, 1), blurRadius: 2),
    BoxShadow(color: Color(0x081E1B4B), offset: Offset(0, 1), blurRadius: 8),
  ];
  // Hover / raised
  static const sh2 = [
    BoxShadow(color: Color(0x141E1B4B), offset: Offset(0, 6), blurRadius: 16),
  ];
  // Primary CTA glow
  static const shPrimary = [
    BoxShadow(color: Color(0x4D6366F1), offset: Offset(0, 6), blurRadius: 18),
  ];
}
