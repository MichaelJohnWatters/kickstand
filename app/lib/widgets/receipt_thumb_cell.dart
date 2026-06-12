// ReceiptThumbCell — renders the inline 50×50 receipt thumbnail the
// server ships base64-encoded in the expense list payload.
//
// Two visual outcomes:
//
//   - bytes present  →  Image.memory at 44×44 (the list-cell size).
//   - bytes empty    →  the supplied fallback widget (currently the
//                       category-stripe placeholder).
//
// Lifted out of instructor_expenses_screen.dart so the receipt tests
// can drive it directly without standing up the whole screen + a
// fixture and a router.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class ReceiptThumbCell extends StatelessWidget {
  final Uint8List thumbBytes;
  final Widget fallback;
  final double size;

  const ReceiptThumbCell({
    super.key,
    required this.thumbBytes,
    required this.fallback,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    if (thumbBytes.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(KsRadius.sm),
      child: Image.memory(
        thumbBytes,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }
}
