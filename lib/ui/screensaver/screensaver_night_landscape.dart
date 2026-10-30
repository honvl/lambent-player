import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A night landscape for an OLED screen: a black sky with stars, two dim
/// aurora ribbons, a thin crescent moon, ridges and pines in black against a
/// faint horizon glow, and a still lake that mirrors the stars. Fireflies drift
/// along the tree line and now and then a shooting star crosses.
///
/// Built for a screensaver that runs for hours: most pixels are true black,
/// nothing bright stays in one place (the stars and moon drift, the aurora
/// moves), and a frame is a few hundred circles and two vertex draws, repainted
/// at [fps] rather than every vsync.
class NightLandscapeBackdrop extends StatefulWidget {
  const NightLandscapeBackdrop({super.key, this.fps = 24});

  final int fps;

  @override
  State<NightLandscapeBackdrop> createState() => _NightLandscapeBackdropState();
}

class _NightLandscapeBackdropState extends State<NightLandscapeBackdrop>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final ValueNotifier<double> _seconds;
  late final double _offset;
  Duration _lastFrame = Duration.zero;

  @override
  void initState() {
    super.initState();
    // Each start picks up a different moment of the night, so the moon and the
    // aurora are not in the same place every time the screensaver comes on.
    _offset = (DateTime.now().millisecondsSinceEpoch / 1000) % 86400;
    _seconds = ValueNotifier<double>(_offset);
    _ticker = createTicker((elapsed) {
      final gap = Duration(milliseconds: (1000 / widget.fps).round());
      if (elapsed - _lastFrame < gap) return;
      _lastFrame = elapsed;
      _seconds.value = _offset + elapsed.inMicroseconds / 1e6;
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: NightLandscapePainter(_seconds),
      ),
    );
  }
}

class _Star {
  const _Star({
    required this.nx,
    required this.ny,
    required this.radius,
    required this.alpha,
    required this.twinkleSpeed,
    required this.phase,
    required this.drift,
    required this.warm,
  });

  final double nx, ny, radius, alpha, twinkleSpeed, phase, drift;
  final bool warm;
}

/// Paints the landscape for the time [seconds] holds. Public so a test can
/// render a frame.
class NightLandscapePainter extends CustomPainter {
  NightLandscapePainter(this.seconds) : super(repaint: seconds);

  final ValueListenable<double> seconds;

  static const _horizonFraction = 0.70;
  static final _stars = _makeStars();

  Size? _builtFor;
  Path _farRidge = Path();
  Path _nearRidge = Path();
  Paint _glowPaint = Paint();
  Paint _lakeGlowPaint = Paint();

  static List<_Star> _makeStars() {
    final random = math.Random(7);
    return List.generate(280, (_) {
      final size = math.pow(random.nextDouble(), 4).toDouble();
      return _Star(
        nx: random.nextDouble(),
        ny: random.nextDouble() * 0.97,
        radius: 0.5 + size * 1.5,
        alpha: 0.22 + 0.6 * random.nextDouble(),
        twinkleSpeed: 0.3 + 1.3 * random.nextDouble(),
        phase: random.nextDouble() * math.pi * 2,
        // Bigger stars drift a little faster, which reads as depth.
        drift: 0.15 + size * 0.6,
        warm: random.nextDouble() < 0.12,
      );
    });
  }

  static double _hash(int n) {
    final x = math.sin(n * 12.9898) * 43758.5453;
    return x - x.floorToDouble();
  }

  void _build(Size size) {
    if (_builtFor == size) return;
    _builtFor = size;
    final w = size.width;
    final h = size.height;
    final horizon = h * _horizonFraction;
    final s = h / 1080;

    double ridge(double x, double a, double b, double c) =>
        0.5 +
        0.5 *
            (0.55 * math.sin(x * 0.0021 + a) +
                0.30 * math.sin(x * 0.0057 + b) +
                0.15 * math.sin(x * 0.0139 + c));

    _farRidge = Path()..moveTo(0, horizon);
    for (var x = 0.0; x <= w + 8; x += 8) {
      _farRidge.lineTo(x, horizon - h * 0.11 * ridge(x, 1.3, 0.4, 2.1));
    }
    _farRidge
      ..lineTo(w, horizon)
      ..close();

    // The near ridge carries the pines: a saw along the line, taller where a
    // slow noise says a stand of trees is.
    _nearRidge = Path()..moveTo(0, horizon);
    const period = 16.0;
    for (var x = 0.0; x <= w + period; x += period / 2) {
      final base = horizon - h * 0.045 * (0.4 + 0.6 * ridge(x, 4.2, 0.9, 5.3));
      final stand = math.max(0.0, ridge(x * 1.7, 2.2, 3.1, 0.2) - 0.35);
      final peak = (x / (period / 2)).round().isEven;
      final tree = peak ? stand * 70 * s * (0.6 + 0.4 * _hash(x.round())) : 0.0;
      _nearRidge.lineTo(x, base - tree);
    }
    _nearRidge
      ..lineTo(w, horizon)
      ..close();

    _glowPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, horizon),
        Offset(0, horizon - h * 0.34),
        const [Color(0x2E3A5C8A), Color(0x00000000)],
      );
    _lakeGlowPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, horizon),
        Offset(0, horizon + h * 0.16),
        const [Color(0x1C2A4468), Color(0x00000000)],
      );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _build(size);
    final t = seconds.value;
    final w = size.width;
    final h = size.height;
    final horizon = h * _horizonFraction;
    final s = h / 1080;

    // The sky is left black. Only the horizon carries a trace of light, which
    // is what makes the ridges read as silhouettes.
    canvas.drawRect(Rect.fromLTRB(0, horizon - h * 0.34, w, horizon), _glowPaint);
    canvas.drawRect(Rect.fromLTRB(0, horizon, w, horizon + h * 0.16), _lakeGlowPaint);

    _paintAurora(canvas, size, t, reflected: false);
    _paintAurora(canvas, size, t, reflected: true);
    _paintStars(canvas, size, t);
    _paintMoon(canvas, size, t);
    _paintShootingStar(canvas, size, t);

    canvas.drawPath(_farRidge, Paint()..color = const Color(0xFF04060A));
    canvas.drawPath(_nearRidge, Paint()..color = Colors.black);

    _paintFireflies(canvas, size, t, s);
  }

  void _paintStars(Canvas canvas, Size size, double t) {
    final w = size.width;
    final h = size.height;
    final horizon = h * _horizonFraction;
    final s = h / 1080;
    final paint = Paint();
    for (final star in _stars) {
      final x = (star.nx * w + t * star.drift * s) % w;
      final y = star.ny * horizon;
      final twinkle = 0.65 + 0.35 * math.sin(t * star.twinkleSpeed + star.phase);
      final base = star.warm ? const Color(0xFFFFEBC8) : const Color(0xFFD2E1FF);
      final alpha = star.alpha * twinkle;
      paint.color = base.withValues(alpha: alpha);
      canvas.drawCircle(Offset(x, y), star.radius * s, paint);

      // The lake mirrors it, dimmer and wavering a little sideways.
      final mirrored = 2 * horizon - y;
      if (mirrored < h) {
        final wobble = math.sin(t * 0.7 + star.phase * 3) * 1.5 * s;
        paint.color = base.withValues(alpha: alpha * 0.20);
        canvas.drawCircle(Offset(x + wobble, mirrored), star.radius * s, paint);
      }
    }
  }

  void _paintAurora(
    Canvas canvas,
    Size size,
    double t, {
    required bool reflected,
  }) {
    final w = size.width;
    final h = size.height;
    final horizon = h * _horizonFraction;
    final s = h / 1080;

    void ribbon({
      required Color color,
      required double peak,
      required double baseY,
      required double thickness,
      required double speed,
      required double seed,
    }) {
      const columns = 96;
      final positions = Float32List(columns * 3 * 2);
      final colors = Int32List(columns * 3);
      for (var i = 0; i < columns; i++) {
        final x = w * i / (columns - 1);
        final wave =
            28 * s * math.sin(x * 0.0040 + t * 0.050 * speed + seed) +
            18 * s * math.sin(x * 0.0110 - t * 0.080 * speed + seed * 2);
        final centre = baseY + wave;
        final half =
            thickness *
            (0.6 + 0.4 * math.sin(x * 0.0060 + t * 0.040 * speed + seed + 1));
        final glow = math.pow(
          0.5 + 0.5 * math.sin(x * 0.0050 - t * 0.030 * speed + seed + 2),
          1.6,
        );
        final strength = peak * glow * (reflected ? 0.30 : 1.0);
        // Top fades up from nothing, the middle is the bright seam, the
        // bottom fades out again a little sooner.
        final ys = [centre - half, centre, centre + half * 0.6];
        final alphas = [0.0, strength, 0.0];
        for (var k = 0; k < 3; k++) {
          final index = i * 3 + k;
          final y = reflected ? 2 * horizon - ys[k] : ys[k];
          positions[index * 2] = x;
          positions[index * 2 + 1] = y;
          colors[index] = color.withValues(alpha: alphas[k]).toARGB32();
        }
      }
      final indices = Uint16List((columns - 1) * 12);
      var n = 0;
      for (var i = 0; i < columns - 1; i++) {
        final top = i * 3, next = (i + 1) * 3;
        for (final (a, b) in const [(0, 1), (1, 2)]) {
          indices[n++] = top + a;
          indices[n++] = top + b;
          indices[n++] = next + a;
          indices[n++] = top + b;
          indices[n++] = next + b;
          indices[n++] = next + a;
        }
      }
      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        colors: colors,
        indices: indices,
      );
      canvas.drawVertices(
        vertices,
        BlendMode.dst,
        Paint()..blendMode = BlendMode.plus,
      );
    }

    ribbon(
      color: const Color(0xFF3CFFAA),
      peak: 0.17,
      baseY: h * 0.30,
      thickness: h * 0.13,
      speed: 1.0,
      seed: 0.0,
    );
    ribbon(
      color: const Color(0xFF9660FF),
      peak: 0.09,
      baseY: h * 0.39,
      thickness: h * 0.10,
      speed: 0.7,
      seed: 3.1,
    );
  }

  void _paintMoon(Canvas canvas, Size size, double t) {
    final w = size.width;
    final h = size.height;
    final horizon = h * _horizonFraction;
    final s = h / 1080;

    // Crosses the sky over two hours and sets behind the ridge, so the one
    // bright thing on the screen never sits still.
    final u = (t / 7200) % 1.0;
    final centre = Offset(
      w * (0.10 + 0.80 * u),
      horizon * 0.94 - math.sin(math.pi * u) * horizon * 0.60,
    );
    final radius = 15 * s;

    canvas.drawCircle(
      centre,
      90 * s,
      Paint()
        ..shader = ui.Gradient.radial(
          centre,
          90 * s,
          const [Color(0x1CBFD0FF), Color(0x00000000)],
        ),
    );

    final disc = Path()..addOval(Rect.fromCircle(center: centre, radius: radius));
    final bite = Path()
      ..addOval(
        Rect.fromCircle(
          center: centre.translate(radius * 0.55, -radius * 0.25),
          radius: radius * 0.92,
        ),
      );
    canvas.drawPath(
      Path.combine(PathOperation.difference, disc, bite),
      Paint()..color = const Color(0xE6F2EBD8),
    );

    // Its path on the water: a few short dashes that shimmer.
    final mirrored = 2 * horizon - centre.dy;
    if (mirrored < h) {
      for (var i = 0; i < 6; i++) {
        final y = mirrored + i * 11 * s;
        final width = (26 - i * 3) * s * (0.8 + 0.2 * math.sin(t * 1.3 + i));
        final shift = math.sin(t * 0.9 + i * 1.7) * 4 * s;
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset(centre.dx + shift, y),
            width: width,
            height: 1.6 * s,
          ),
          Paint()..color = const Color(0xFFF2EBD8).withValues(alpha: 0.16 - i * 0.02),
        );
      }
    }
  }

  void _paintShootingStar(Canvas canvas, Size size, double t) {
    const period = 55.0;
    final cycle = (t / period).floor();
    final local = t - cycle * period;
    final start = 8 + 30 * _hash(cycle * 3 + 1);
    const duration = 1.1;
    if (local < start || local > start + duration) return;

    final w = size.width;
    final h = size.height;
    final s = h / 1080;
    final progress = (local - start) / duration;
    final from = Offset(
      w * (0.25 + 0.65 * _hash(cycle * 3 + 2)),
      h * _horizonFraction * (0.06 + 0.30 * _hash(cycle * 3 + 3)),
    );
    const direction = Offset(-0.87, 0.49);
    final length = 260 * s;
    final head = from + direction * (length * progress * 1.6);
    final tail = head - direction * (length * 0.35);
    final fade = math.sin(math.pi * progress);
    canvas.drawLine(
      tail,
      head,
      Paint()
        ..strokeWidth = 1.6 * s
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(
          tail,
          head,
          [const Color(0x00FFFFFF), Colors.white.withValues(alpha: 0.85 * fade)],
        ),
    );
  }

  void _paintFireflies(Canvas canvas, Size size, double t, double s) {
    final w = size.width;
    final h = size.height;
    final horizon = h * _horizonFraction;
    final paint = Paint();
    for (var i = 0; i < 16; i++) {
      final bx = w * (0.06 + 0.88 * _hash(i * 5 + 1));
      final by = horizon - h * (0.02 + 0.07 * _hash(i * 5 + 2));
      final x = bx + 46 * s * math.sin(t * 0.13 + _hash(i * 5 + 3) * 6.28);
      final y = by + 24 * s * math.sin(t * 0.21 + _hash(i * 5 + 4) * 6.28);
      final pulse = math.pow(
        math.max(0.0, math.sin(t * 0.55 + _hash(i * 5 + 5) * 6.28)),
        3,
      );
      if (pulse < 0.02) continue;
      paint.color = const Color(0xFFFFD27A).withValues(alpha: 0.10 * pulse);
      canvas.drawCircle(Offset(x, y), 7 * s, paint);
      paint.color = const Color(0xFFFFE3A0).withValues(alpha: 0.85 * pulse);
      canvas.drawCircle(Offset(x, y), 1.5 * s, paint);
    }
  }

  @override
  bool shouldRepaint(NightLandscapePainter oldDelegate) =>
      oldDelegate.seconds != seconds;
}
