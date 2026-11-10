import 'dart:math' as math;
import 'package:flutter/material.dart';

enum AssistantOrbState {
  idle,
  listening,
  thinking,
  speaking,
  tools,
  connecting,
  disconnected,
  paused,
  error
}

/// A single small, isolated animated surface. Shape and glyph communicate the
/// state as well as color; labels remain available to screen readers.
class AssistantOrb extends StatefulWidget {
  const AssistantOrb({super.key, required this.state});
  final AssistantOrbState state;
  @override
  State<AssistantOrb> createState() => _AssistantOrbState();
}

class _AssistantOrbState extends State<AssistantOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  bool get _moving =>
      !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.of(context) &&
      const {
        AssistantOrbState.listening,
        AssistantOrbState.thinking,
        AssistantOrbState.speaking,
        AssistantOrbState.tools,
        AssistantOrbState.connecting,
      }.contains(widget.state);
  void _syncMotion() {
    if (_moving) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion.stop();
      _motion.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant AssistantOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = switch (widget.state) {
      AssistantOrbState.idle => 'Book assistant',
      AssistantOrbState.listening => 'Listening',
      AssistantOrbState.thinking => 'Thinking',
      AssistantOrbState.speaking =>
        'Speaking; interrupt with your voice or tap',
      AssistantOrbState.tools => 'Working with reader tools',
      AssistantOrbState.connecting => 'Connecting',
      AssistantOrbState.disconnected => 'Disconnected',
      AssistantOrbState.paused => 'Microphone paused',
      AssistantOrbState.error => 'Assistant needs attention',
    };
    return Semantics(
      label: label,
      liveRegion: true,
      child: RepaintBoundary(
          child: SizedBox.square(
        dimension: 40,
        child: CustomPaint(painter: _OrbPainter(widget.state, _motion, colors)),
      )),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.state, this.motion, this.colors) : super(repaint: motion);
  final AssistantOrbState state;
  final Animation<double> motion;
  final ColorScheme colors;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero), phase = motion.value * math.pi * 2;
    final rect = Offset.zero & size;
    final muted =
        state == AssistantOrbState.paused || state == AssistantOrbState.idle;
    final failed = state == AssistantOrbState.error ||
        state == AssistantOrbState.disconnected;
    final palette = failed
        ? [colors.error, colors.errorContainer, colors.error]
        : muted
            ? [colors.outline, colors.surfaceContainerHighest, colors.outline]
            : [
                colors.primary,
                colors.tertiary,
                colors.secondary,
                colors.primary
              ];
    final contour = Path();
    final amplitude = state == AssistantOrbState.listening ||
            state == AssistantOrbState.speaking
        ? 1.9
        : .8;
    for (var i = 0; i <= 96; i++) {
      final a = i / 96 * math.pi * 2;
      final radius = 16 +
          amplitude * math.sin(a * 3 + phase) +
          .7 * math.sin(a * 4 - phase);
      final p = center + Offset(math.cos(a), math.sin(a)) * radius;
      if (i == 0) {
        contour.moveTo(p.dx, p.dy);
      } else {
        contour.lineTo(p.dx, p.dy);
      }
    }
    contour.close();
    canvas.drawPath(
        contour,
        Paint()
          ..shader = SweepGradient(
            colors: palette,
            transform: GradientRotation(phase * .3),
          ).createShader(rect));
    canvas.drawCircle(
        center, 12.5, Paint()..color = colors.surfaceContainerHigh);
    final ink = Paint()
      ..color = failed ? colors.error : colors.onSurface
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    switch (state) {
      case AssistantOrbState.listening:
      case AssistantOrbState.speaking:
        for (var i = 0; i < 4; i++) {
          final h = 3 +
              (math.sin(phase * 2 + i * 1.3) + 1) *
                  (state == AssistantOrbState.listening ? 2 : 3);
          final x = center.dx + (i - 1.5) * 4;
          canvas.drawLine(
              Offset(x, center.dy - h), Offset(x, center.dy + h), ink);
        }
        if (state == AssistantOrbState.listening) {
          canvas.drawCircle(center + const Offset(11, -11), 3,
              Paint()..color = colors.onSurface);
        }
      case AssistantOrbState.thinking:
        for (var i = 0; i < 3; i++) {
          final a = phase + i * math.pi * 2 / 3;
          canvas.drawCircle(center + Offset(math.cos(a), math.sin(a)) * 6, 2,
              ink..style = PaintingStyle.fill);
        }
      case AssistantOrbState.tools:
        for (var i = 0; i < 3; i++) {
          final a = -phase + i * math.pi * 2 / 3;
          final p = center + Offset(math.cos(a), math.sin(a)) * 6;
          canvas.save();
          canvas.translate(p.dx, p.dy);
          canvas.rotate(phase);
          canvas.drawRRect(
              RRect.fromRectAndRadius(
                  const Rect.fromLTWH(-2, -2, 4, 4), const Radius.circular(.7)),
              ink);
          canvas.restore();
        }
      case AssistantOrbState.connecting:
        for (var i = 0; i < 3; i++) {
          canvas.drawArc(Rect.fromCircle(center: center, radius: 7),
              phase + i * 2.1, 1.1, false, ink);
        }
      case AssistantOrbState.disconnected:
        canvas.drawArc(
            Rect.fromCircle(center: center - const Offset(2, 2), radius: 5),
            .8,
            3.5,
            false,
            ink);
        canvas.drawArc(
            Rect.fromCircle(center: center + const Offset(2, 2), radius: 5),
            4,
            3.5,
            false,
            ink);
        canvas.drawLine(
            center + const Offset(-7, 7), center + const Offset(7, -7), ink);
      case AssistantOrbState.paused:
        canvas.drawLine(
            center + const Offset(-3, -5), center + const Offset(-3, 5), ink);
        canvas.drawLine(
            center + const Offset(3, -5), center + const Offset(3, 5), ink);
      case AssistantOrbState.error:
        canvas.drawLine(
            center - const Offset(0, 6), center + const Offset(0, 1), ink);
        canvas.drawCircle(
            center + const Offset(0, 6), 1, ink..style = PaintingStyle.fill);
      case AssistantOrbState.idle:
        final star = Path()
          ..moveTo(center.dx, center.dy - 7)
          ..quadraticBezierTo(
              center.dx + 1, center.dy - 1, center.dx + 7, center.dy)
          ..quadraticBezierTo(
              center.dx + 1, center.dy + 1, center.dx, center.dy + 7)
          ..quadraticBezierTo(
              center.dx - 1, center.dy + 1, center.dx - 7, center.dy)
          ..quadraticBezierTo(
              center.dx - 1, center.dy - 1, center.dx, center.dy - 7)
          ..close();
        canvas.drawPath(star, ink);
    }
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.state != state || old.colors != colors || old.motion != motion;
}
