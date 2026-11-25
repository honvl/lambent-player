import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

/// How much buffer the player wants ahead of the playhead before it resumes
/// after a stall: media3's `DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS`,
/// which `Media3VideoView.buildLoadControl` keeps.
const stallResumeBuffer = Duration(seconds: 2);

/// How far a stalled player is toward resuming, from 0 to 1.
///
/// On the seek bar's own scale the buffered stretch is a sliver: a few
/// seconds of a two hour film is a pixel or two. Measured against what the
/// player is waiting for, the same seconds fill a stretch that can be seen.
double stallFillFraction({
  required Duration position,
  required Duration buffered,
  Duration target = stallResumeBuffer,
}) {
  final ahead = (buffered - position).inMilliseconds;
  if (ahead <= 0 || target.inMilliseconds <= 0) return 0;
  return (ahead / target.inMilliseconds).clamp(0.0, 1.0);
}

/// Shows what [builder] draws while playback is [stalled], and lets it leave
/// slowly.
///
/// Nothing shows for the first [wait] of a stall, so one too short to matter
/// never flashes. When the stall ends the drawing stays and fades to nothing
/// over [fadeOut]: a stall often ends the moment its meter fills, and a meter
/// that vanished at once would never be seen full.
class StallFade extends StatefulWidget {
  final bool stalled;

  /// Something else is showing the stall, so this one goes at once.
  final bool suppressed;

  final WidgetBuilder builder;

  const StallFade({
    super.key,
    required this.stalled,
    this.suppressed = false,
    required this.builder,
  });

  static const wait = Duration(milliseconds: 450);
  static const fadeIn = Duration(milliseconds: 350);
  static const fadeOut = Duration(milliseconds: 1200);

  @override
  State<StallFade> createState() => _StallFadeState();
}

class _StallFadeState extends State<StallFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _opacity = AnimationController(vsync: this);
  Timer? _waiting;

  bool get _showing => widget.stalled && !widget.suppressed;

  @override
  void initState() {
    super.initState();
    if (_showing) _begin();
  }

  @override
  void didUpdateWidget(StallFade old) {
    super.didUpdateWidget(old);
    if (widget.suppressed) {
      _waiting?.cancel();
      _waiting = null;
      _opacity.value = 0;
      return;
    }
    if (_showing == (old.stalled && !old.suppressed)) return;
    _showing ? _begin() : _end();
  }

  void _begin() {
    // Still on screen from the last stall: come straight back.
    if (_opacity.value > 0) {
      _opacity.animateTo(1, duration: StallFade.fadeIn, curve: Curves.easeOut);
      return;
    }
    _waiting?.cancel();
    _waiting = Timer(StallFade.wait, () {
      if (!mounted) return;
      _opacity.animateTo(1, duration: StallFade.fadeIn, curve: Curves.easeOut);
    });
  }

  void _end() {
    _waiting?.cancel();
    _waiting = null;
    if (_opacity.value == 0) return;
    // Slow to start, so the full meter is seen before it thins out.
    _opacity.animateTo(0, duration: StallFade.fadeOut, curve: Curves.easeIn);
  }

  @override
  void dispose() {
    _waiting?.cancel();
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacity,
      builder: (context, _) {
        if (_opacity.value == 0) return const SizedBox.shrink();
        return IgnorePointer(
          child: Opacity(
            opacity: _opacity.value,
            child: widget.builder(context),
          ),
        );
      },
    );
  }
}

/// The stall's drawing on a seek bar track: light crossing the stretch ahead
/// of the playhead, and just past the playhead a short meter that fills as
/// the buffer comes back.
///
/// Laid over the player's own slider it leaves the played part and the thumb
/// alone, so the position stays readable. [standalone] draws the track and
/// the played part as well, for when the controls are hidden.
class StallTrack extends StatefulWidget {
  /// The playhead along the track, 0 to 1.
  final double position;

  /// From [stallFillFraction].
  final double fill;

  final double height;
  final bool standalone;

  /// Kept clear around the playhead, where the slider draws its thumb.
  final double thumbRadius;

  const StallTrack({
    super.key,
    required this.position,
    required this.fill,
    this.height = 8,
    this.standalone = false,
    this.thumbRadius = 0,
  });

  @override
  State<StallTrack> createState() => _StallTrackState();
}

class _StallTrackState extends State<StallTrack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: widget.fill.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        builder: (context, fill, _) => SizedBox(
          height: widget.height,
          width: double.infinity,
          child: CustomPaint(
            painter: _StallPainter(
              position: widget.position.clamp(0.0, 1.0),
              fill: fill,
              sweep: _sweep,
              standalone: widget.standalone,
              thumbRadius: widget.thumbRadius,
              played: AppColorScheme.rangeProgress,
            ),
          ),
        ),
      ),
    );
  }
}

class _StallPainter extends CustomPainter {
  final double position;
  final double fill;
  final Animation<double> sweep;
  final bool standalone;
  final double thumbRadius;
  final Color played;

  _StallPainter({
    required this.position,
    required this.fill,
    required this.sweep,
    required this.standalone,
    required this.thumbRadius,
    required this.played,
  }) : super(repaint: sweep);

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final track = RRect.fromRectAndRadius(Offset.zero & size, radius);
    final playhead = size.width * position;

    if (standalone) {
      canvas.drawRRect(track, Paint()..color = const Color(0x52FFFFFF));
      if (playhead > 0) {
        canvas.save();
        canvas.clipRRect(track);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, playhead, size.height),
          Paint()..color = played,
        );
        canvas.restore();
      }
    }

    // Everything else belongs to the stretch that hasn't played.
    final start = math.min(playhead + thumbRadius, size.width);
    final ahead = size.width - start;
    if (ahead <= 0) return;
    canvas.save();
    canvas.clipRRect(track);
    canvas.clipRect(Rect.fromLTWH(start, 0, ahead, size.height));

    // Light crossing it, so the wait shows before anything has arrived.
    final band = math.max(ahead * 0.3, 48.0);
    final left = start - band + (ahead + band) * sweep.value;
    final bandRect = Rect.fromLTWH(left, 0, band, size.height);
    canvas.drawRect(
      bandRect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x00FFFFFF), Color(0xB3FFFFFF), Color(0x00FFFFFF)],
        ).createShader(bandRect),
    );

    // The meter: this much track stands for the wait to resume, since the
    // seconds themselves would be a pixel wide.
    final span = math.min(ahead, math.max(size.width * 0.22, 56.0));
    canvas.drawRect(
      Rect.fromLTWH(start, 0, span, size.height),
      Paint()..color = const Color(0x40FFFFFF),
    );
    if (fill > 0) {
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          start,
          0,
          start + span * fill,
          size.height,
          topRight: radius,
          bottomRight: radius,
        ),
        Paint()..color = const Color(0xF2FFFFFF),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StallPainter old) =>
      old.position != position ||
      old.fill != fill ||
      old.standalone != standalone ||
      old.thumbRadius != thumbRadius ||
      old.played != played;
}

/// The stall's drawing on a slim timeline of its own, on the glass bar's
/// tint, for a stall while the player's controls are hidden. It sits where
/// the bar would.
class StallPill extends StatelessWidget {
  final double position;
  final double fill;

  const StallPill({super.key, required this.position, required this.fill});

  static const double _radius = 20;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x8C101218),
        borderRadius: AppRadius.circular(_radius),
      ),
      child: CustomPaint(
        foregroundPainter: GlassHairlinePainter(radius: _radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.spaceLg,
            vertical: AppSpacing.spaceMd,
          ),
          child: StallTrack(position: position, fill: fill, standalone: true),
        ),
      ),
    );
  }
}
