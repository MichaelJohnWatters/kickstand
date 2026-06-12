import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Circular X-of-Y progress indicator used in the Assess header
/// (matches `ProgressRing` from the design handoff). The arc spans
/// from 12-o'clock, clockwise; `value` / `total` determines its sweep.
class KsProgressRing extends StatelessWidget {
  final int value;
  final int total;
  final double size;
  final double strokeWidth;
  final Color colour;
  final Widget? child;
  const KsProgressRing({
    required this.value,
    required this.total,
    this.size = 46,
    this.strokeWidth = 5,
    this.colour = const Color(0xFF6366F1),
    this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          value: value,
          total: total,
          strokeWidth: strokeWidth,
          colour: colour,
        ),
        child: Center(child: child),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final int value;
  final int total;
  final double strokeWidth;
  final Color colour;
  _RingPainter({
    required this.value,
    required this.total,
    required this.strokeWidth,
    required this.colour,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = colour.withValues(alpha: 0.15);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = colour;

    canvas.drawCircle(centre, radius, track);
    if (total <= 0 || value <= 0) return;
    final pct = (value / total).clamp(0, 1).toDouble();
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      -math.pi / 2,
      pct * 2 * math.pi,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value ||
      old.total != total ||
      old.strokeWidth != strokeWidth ||
      old.colour != colour;
}
