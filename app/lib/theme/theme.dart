// Material ThemeData built from tokens. Plus Jakarta Sans for UI, Space Mono
// for plates/refs/codes — both via google_fonts so we don't ship .ttf assets.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

ThemeData buildKsTheme() {
  final base = ThemeData(brightness: Brightness.light, useMaterial3: true);

  final textTheme = GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(
    bodyColor: KsColors.ink,
    displayColor: KsColors.ink,
  );

  // Headlines use tight tracking + weight 800 per tokens.css.
  TextStyle? tight(TextStyle? s, {double tracking = -0.03, FontWeight w = FontWeight.w800}) =>
      s?.copyWith(letterSpacing: s.fontSize == null ? null : s.fontSize! * tracking, fontWeight: w, color: KsColors.ink);

  final headed = textTheme.copyWith(
    displayLarge: tight(textTheme.displayLarge),
    displayMedium: tight(textTheme.displayMedium),
    displaySmall: tight(textTheme.displaySmall),
    headlineLarge: tight(textTheme.headlineLarge),
    headlineMedium: tight(textTheme.headlineMedium),
    headlineSmall: tight(textTheme.headlineSmall),
    titleLarge: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: KsColors.ink),
    titleMedium: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: KsColors.ink),
    titleSmall: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: KsColors.ink2),
    bodyLarge: textTheme.bodyLarge?.copyWith(color: KsColors.ink),
    bodyMedium: textTheme.bodyMedium?.copyWith(color: KsColors.ink2),
    bodySmall: textTheme.bodySmall?.copyWith(color: KsColors.ink3),
    labelLarge: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: KsColors.ink),
  );

  final colorScheme = ColorScheme.fromSeed(
    seedColor: KsColors.primary,
    brightness: Brightness.light,
    primary: KsColors.primary,
    onPrimary: Colors.white,
    surface: KsColors.surface,
    onSurface: KsColors.ink,
    error: KsColors.danger,
    onError: Colors.white,
  );

  return base.copyWith(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: KsColors.bg,
    textTheme: headed,
    appBarTheme: const AppBarTheme(
      backgroundColor: KsColors.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: KsColors.ink,
      elevation: 0,
      centerTitle: false,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: KsColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KsRadius.md)),
        // Bounded minWidth — `Size.fromHeight(48)` is shorthand for
        // `Size(double.infinity, 48)`, which forces minWidth=infinity and
        // explodes in any list-item slot whose constraint chain isn't
        // tightly bounded. Wrap a specific button in `SizedBox(width: …)`
        // or `Row > Expanded` if you want it to fill width.
        minimumSize: const Size(64, 48),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: KsColors.ink,
        side: const BorderSide(color: KsColors.border2, width: 1),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w600, fontSize: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KsRadius.md)),
        minimumSize: const Size(64, 48),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: KsColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KsRadius.md),
        borderSide: const BorderSide(color: KsColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KsRadius.md),
        borderSide: const BorderSide(color: KsColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KsRadius.md),
        borderSide: const BorderSide(color: KsColors.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KsRadius.md),
        borderSide: const BorderSide(color: KsColors.danger),
      ),
      labelStyle: GoogleFonts.plusJakartaSans(color: KsColors.ink3),
    ),
    cardTheme: CardThemeData(
      color: KsColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KsRadius.lg),
        side: const BorderSide(color: KsColors.border),
      ),
    ),
    dividerColor: KsColors.border,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
  );
}

// Convenience accessor for the mono face (plates, registrations, codes).
TextStyle ksMono({double size = 13, FontWeight weight = FontWeight.w500, Color? color}) =>
    GoogleFonts.spaceMono(fontSize: size, fontWeight: weight, color: color ?? KsColors.ink);
