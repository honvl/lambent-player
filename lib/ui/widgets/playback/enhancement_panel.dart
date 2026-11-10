import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:playback_core/playback_core.dart';

import '../../../util/focus/dpad_keys.dart';
import '../../../util/platform_detection.dart';
import '../focus/focus_theme.dart';
import '../focusable_dialog_row.dart';
import '../track_selector_dialog.dart';

/// The controls for what Lambent Server's PC enhancer does to the stream:
/// upscaling quality, Auto HDR, Dolby Vision, Deepen blacks, and the picture
/// (saturation, contrast, brightness, peak brightness, hue).
///
/// An on/off row applies when it is pressed, so Compare shows what it compares
/// at once; so does Frame interpolation, this screen's own choice for 2D titles,
/// kept for later plays. HDR strength, saturation, contrast, brightness, hue and
/// wide colour change while the stream plays ([onLive]), and show once what the
/// player has buffered has played. The quality and peak brightness stay pending
/// until Apply: each reopens the stream, and the enhancer takes a few seconds to
/// start again. A control whose setting the stream's URL does not carry is left out,
/// since the server cannot honour it.
Future<void> showEnhancementPanel(
  BuildContext context, {
  required LambentEnhancement current,
  required bool enhanced,
  required void Function(bool on) onSetEnhancement,
  required void Function(LambentEnhancement chosen) onApply,
  required void Function(LambentEnhancement chosen) onLive,
  required Duration Function() liveDelay,
  required VoidCallback onShowLiveNow,
  required VoidCallback onReset,
  required VoidCallback onShowStreamInfo,
  String? status,
  bool compareOnly = false,
  String? deviceUpscale,
  EnhancementInterpolation? interpolation,
  bool useRootNavigator = false,
}) {
  return showStyledPlayerDialog<void>(
    context,
    title: 'Lambent enhancement',
    // The server's Lambent Enhance status when it is known.
    subtitle: status ?? 'Made live on your PC while you watch',
    sidePanel: true,
    maxWidth: 480,
    useRootNavigator: useRootNavigator,
    builder: (dialogContext) {
      void close() =>
          Navigator.of(dialogContext, rootNavigator: useRootNavigator).pop();
      return _EnhancementPanelBody(
        current: current,
        enhanced: enhanced,
        compareOnly: compareOnly,
        deviceUpscale: deviceUpscale,
        interpolation: interpolation == null
            ? null
            : (
                on: interpolation.on,
                streamFps: interpolation.streamFps,
                onSet: (on) {
                  close();
                  interpolation.onSet(on);
                },
              ),
        onSetEnhancement: (on) {
          close();
          onSetEnhancement(on);
        },
        onApply: (chosen) {
          close();
          onApply(chosen);
        },
        onLive: onLive,
        liveDelay: liveDelay,
        onShowLiveNow: () {
          close();
          onShowLiveNow();
        },
        onReset: () {
          close();
          onReset();
        },
        onShowStreamInfo: () {
          close();
          onShowStreamInfo();
        },
      );
    },
  );
}

/// The frame interpolation row: offered only where the server's PC
/// interpolates and the title's source is slow enough to double. [on] is this
/// screen's choice; [streamFps] the rate the stream plays at when the PC
/// interpolates it, null when it doesn't (yet).
typedef EnhancementInterpolation = ({
  bool on,
  double? streamFps,
  void Function(bool on) onSet,
});

const _qualityNames = <int, String>{
  1: '1 · Fastest',
  2: '2',
  3: '3',
  4: '4 · Best',
};

typedef _Range = ({int min, int max});

/// "Off", "On", or "On · 48 fps" once the stream is at the doubled rate:
/// 47.952 shows as 48, 59.94 as itself.
String _interpolationLabel(EnhancementInterpolation fi) {
  final fps = fi.streamFps;
  if (!fi.on) return 'Off';
  if (fps == null) return 'On';
  final whole = fps.round();
  final shown = (fps - whole).abs() < 0.05
      ? '$whole'
      : fps.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
  return 'On · $shown fps';
}

double _fraction(int value, _Range range) =>
    (value - range.min) / (range.max - range.min);

/// The value at [fraction] of [range], on the [step] grid from its bottom.
int _valueAt(double fraction, int step, _Range range) {
  final span = range.max - range.min;
  final steps = (fraction.clamp(0.0, 1.0) * span / step).round();
  return (range.min + steps * step).clamp(range.min, range.max);
}

class _EnhancementPanelBody extends StatefulWidget {
  const _EnhancementPanelBody({
    required this.current,
    required this.enhanced,
    required this.onSetEnhancement,
    required this.onApply,
    required this.onLive,
    required this.liveDelay,
    required this.onShowLiveNow,
    required this.onReset,
    required this.onShowStreamInfo,
    this.compareOnly = false,
    this.deviceUpscale,
    this.interpolation,
  });

  final LambentEnhancement current;

  /// The frame interpolation row; null where it is not offered.
  final EnhancementInterpolation? interpolation;

  /// The plan's upscale on this device ("AI upscale", "Shader upscale",
  /// "Starting"), null when the plan does not give this device one. Shown,
  /// not set: the plan decides where each step runs.
  final String? deviceUpscale;

  /// The server has no Lambent Enhance and no trial: enhancement exists only
  /// as the split-screen compare, so the on/off row is the compare.
  final bool compareOnly;

  /// Whether the stream is the PC-enhanced one. When it is not, the panel
  /// offers only the way back on.
  final bool enhanced;
  final void Function(bool on) onSetEnhancement;
  final void Function(LambentEnhancement chosen) onApply;

  /// A picture control that changes while the stream plays has changed.
  final void Function(LambentEnhancement chosen) onLive;

  /// How long until what the player gets next is on screen.
  final Duration Function() liveDelay;
  final VoidCallback onShowLiveNow;
  final VoidCallback onReset;
  final VoidCallback onShowStreamInfo;

  @override
  State<_EnhancementPanelBody> createState() => _EnhancementPanelBodyState();
}

class _EnhancementPanelBodyState extends State<_EnhancementPanelBody> {
  late LambentEnhancement _pending = widget.current;

  /// When the last live change reaches the picture; null before the first.
  DateTime? _liveDue;
  Timer? _liveCountdown;

  bool get _changed => !_pending.sameStream(widget.current);

  void _changeLive(LambentEnhancement next) {
    setState(() {
      _pending = next;
      _liveDue = DateTime.now().add(widget.liveDelay());
    });
    widget.onLive(widget.current.withLookOf(next));
    _liveCountdown ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _liveCountdown?.cancel();
    super.dispose();
  }

  String _onOff(bool? value) => value == true ? 'On' : 'Off';

  /// Steps [value] by [dir] * [step] inside [range]. A select press at the top
  /// wraps to the bottom; left and right stop at the ends.
  int _stepped(int value, int dir, int step, _Range range, bool wrap) {
    final next = value + dir * step;
    if (next > range.max) return wrap ? range.min : range.max;
    if (next < range.min) return range.min;
    return next;
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.current;
    final pending = _pending;
    final hdrOn = pending.hdr == true;
    var first = true;
    bool autofocusNext() {
      final value = first;
      first = false;
      return value;
    }

    Widget number({
      required String label,
      required int? value,
      required int step,
      required _Range range,
      required LambentEnhancement Function(int) set,
      String unit = '',
      bool needsHdr = false,
      bool live = true,
      int? origin,
      String? zeroLabel,
    }) {
      final enabled = !needsHdr || hdrOn;
      final shown = value == 0 && zeroLabel != null ? zeroLabel : '$value$unit';
      void change(LambentEnhancement next) {
        if (live) {
          _changeLive(next);
        } else {
          setState(() => _pending = next);
        }
      }

      return _EnhancementRow(
        autofocus: autofocusNext(),
        label: label,
        value: enabled ? shown : 'Needs Auto HDR',
        dimmed: !enabled,
        slider: (
          value: _fraction(value!, range),
          origin: _fraction(origin ?? range.min, range),
        ),
        stepper: true,
        onStep: (dir, wrap) {
          if (!enabled) return;
          change(set(_stepped(value, dir, step, range, wrap)));
        },
        onSlide: enabled
            ? (fraction) {
                final next = _valueAt(fraction, step, range);
                if (next != value) change(set(next));
              }
            : null,
      );
    }

    Widget toggle({
      required String label,
      required bool? value,
      required LambentEnhancement Function(bool) set,
      String? disabledReason,
    }) {
      final enabled = disabledReason == null;
      return _EnhancementRow(
        autofocus: autofocusNext(),
        label: label,
        value: enabled ? _onOff(value) : disabledReason,
        dimmed: !enabled,
        // Only a press, so that left or right on the way past cannot restart
        // the stream. Anything else still pending goes with it.
        onStep: (_, press) {
          if (enabled && press) widget.onApply(set(!(value ?? false)));
        },
      );
    }

    final upscaleRows = <Widget>[
      if (cur.quality != null)
        _EnhancementRow(
          autofocus: autofocusNext(),
          label: 'Upscaling quality',
          value: _qualityNames[pending.quality ?? 4] ?? '4',
          stepper: true,
          onStep: (dir, wrap) => setState(() {
            _pending = pending.copyWith(
              quality: _stepped(
                pending.quality ?? 4,
                dir,
                1,
                LambentEnhancement.qualityRange,
                wrap,
              ),
            );
          }),
        ),
      if (cur.hdr != null)
        toggle(
          label: 'Auto HDR',
          value: pending.hdr,
          // Dolby Vision cannot outlive the HDR picture it rides on, and comes
          // on with it (the owner's choice); its own row turns it off again.
          set: (on) => pending.copyWith(
            hdr: on,
            dolbyVision: on
                ? (LambentEnhancement.dolbyVisionWithHdr || (pending.dolbyVision ?? false))
                : false,
          ),
        ),
      if (cur.dolbyVision != null)
        toggle(
          label: 'Dolby Vision',
          value: pending.dolbyVision,
          disabledReason: hdrOn ? null : 'Needs Auto HDR',
          set: (on) => pending.copyWith(dolbyVision: on),
        ),
      if (cur.deepenBlacks != null)
        toggle(
          label: 'Deepen blacks',
          value: pending.deepenBlacks,
          set: (on) => pending.copyWith(deepenBlacks: on),
        ),
      // The server only names `cmp` while it is on, so any enhanced stream
      // offers it. Under compareOnly it is the on/off row instead.
      if (cur.quality != null && !widget.compareOnly)
        toggle(
          label: 'Compare with original',
          value: pending.compare ?? false,
          set: (on) => pending.copyWith(compare: on),
        ),
      if (widget.interpolation case final fi?)
        _EnhancementRow(
          autofocus: autofocusNext(),
          label: 'Frame interpolation',
          value: _interpolationLabel(fi),
          // Only a press, as for the other on/off rows: it reopens the stream.
          onStep: (_, press) {
            if (press) fi.onSet(!fi.on);
          },
        ),
      if (widget.deviceUpscale != null)
        _EnhancementRow(
          label: 'On this device',
          value: widget.deviceUpscale!,
          onStep: (_, _) {},
        ),
    ];

    final pictureRows = <Widget>[
      if (cur.hdrStrength != null)
        number(
          label: 'HDR strength',
          value: pending.hdrStrength,
          step: 10,
          range: LambentEnhancement.hdrStrengthRange,
          unit: '%',
          needsHdr: true,
          set: (v) => pending.copyWith(hdrStrength: v),
        ),
      if (cur.saturation != null)
        number(
          label: 'Saturation',
          value: pending.saturation,
          step: 10,
          range: LambentEnhancement.saturationRange,
          set: (v) => pending.copyWith(saturation: v),
        ),
      if (cur.contrast != null)
        number(
          label: 'Contrast',
          value: pending.contrast,
          step: 10,
          range: LambentEnhancement.contrastRange,
          needsHdr: true,
          set: (v) => pending.copyWith(contrast: v),
        ),
      if (cur.peakNits != null)
        number(
          label: 'Peak brightness',
          value: pending.peakNits,
          step: 50,
          range: LambentEnhancement.peakRange,
          unit: ' nits',
          needsHdr: true,
          live: false,
          set: (v) => pending.copyWith(peakNits: v),
        ),
    ];

    // Acts at once rather than waiting for Apply: it swaps the whole stream.
    final enhancementRow = _EnhancementRow(
      autofocus: autofocusNext(),
      label: widget.compareOnly ? 'Compare with original' : 'PC enhancement',
      value: widget.enhanced ? 'On' : 'Off · original file',
      onStep: (_, _) => widget.onSetEnhancement(!widget.enhanced),
    );
    if (!widget.enhanced) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            enhancementRow,
            if (widget.deviceUpscale != null)
              _EnhancementRow(
                label: 'On this device',
                value: widget.deviceUpscale!,
                onStep: (_, _) {},
              ),
            const SizedBox(height: 8),
            FocusableDialogRow(
              icon: Icons.info_outline_rounded,
              label: 'Stream info',
              onTap: widget.onShowStreamInfo,
            ),
          ],
        ),
      );
    }

    final liveLeft = _liveDue?.difference(DateTime.now()).inSeconds ?? 0;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          enhancementRow,
          ...upscaleRows,
          if (pictureRows.isNotEmpty) ...[
            const _SectionLabel('Picture'),
            ...pictureRows,
          ],
          const SizedBox(height: 8),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.08)),
          const SizedBox(height: 8),
          if (liveLeft > 0)
            FocusableDialogRow(
              icon: Icons.bolt_rounded,
              label: 'Show now, or wait about $liveLeft s',
              onTap: widget.onShowLiveNow,
            ),
          FocusableDialogRow(
            icon: Icons.check_rounded,
            label: _changed ? 'Apply and restart stream' : 'Apply',
            dimmed: !_changed,
            autofocus: first,
            onTap: () {
              if (_changed) widget.onApply(_pending);
            },
          ),
          FocusableDialogRow(
            icon: Icons.restart_alt_rounded,
            label: 'Reset to server settings',
            onTap: widget.onReset,
          ),
          FocusableDialogRow(
            icon: Icons.info_outline_rounded,
            label: 'Stream info',
            onTap: widget.onShowStreamInfo,
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.54),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

/// A label on the left and its value on the right. Select, or left and right,
/// steps the value; the focused row fills white like the other dialog rows.
class _EnhancementRow extends StatefulWidget {
  const _EnhancementRow({
    required this.label,
    required this.value,
    required this.onStep,
    this.autofocus = false,
    this.dimmed = false,
    this.slider,
    this.stepper = false,
    this.onSlide,
  });

  final String label;
  final String value;

  /// Draws a track under the row, filled from [origin] to [value], both as
  /// fractions of the range. Left and right still step it.
  final ({double value, double origin})? slider;

  /// Called with -1 or 1; the flag is true for a select press, which wraps at
  /// the top of a range.
  final void Function(int dir, bool wrap) onStep;
  final bool autofocus;
  final bool dimmed;

  /// A value with more than two settings. On a touch screen it gets minus
  /// and plus buttons, and a tap on the row no longer steps it, so a stray
  /// tap cannot wrap it from the top to the bottom.
  final bool stepper;

  /// Sets the value from a fraction of the track, for a drag or a tap on the
  /// slider on a touch screen. Null when the value cannot change.
  final void Function(double fraction)? onSlide;

  @override
  State<_EnhancementRow> createState() => _EnhancementRowState();
}

class _EnhancementRowState extends State<_EnhancementRow> {
  bool _focused = false;

  /// The Select press that opened the panel can still be arriving (held keys
  /// repeat, and the key-up lands on whatever has focus by then), and the first
  /// row takes focus the moment the panel opens. Select is ignored for a moment
  /// so opening the panel never changes a value.
  final DateTime _born = DateTime.now();
  static const _settle = Duration(milliseconds: 500);

  /// Touch screens get buttons and draggable sliders; a remote keeps stepping
  /// with left, right and select.
  static bool get _touch => !PlatformDetection.isTV;

  Widget _stepButton(IconData icon, int dir, Color color) => SizedBox(
    width: 44,
    height: 44,
    child: IconButton(
      onPressed: widget.dimmed ? null : () => widget.onStep(dir, false),
      icon: Icon(icon, size: 22),
      color: color,
      disabledColor: color.withValues(alpha: 0.3),
      padding: EdgeInsets.zero,
      tooltip: dir < 0 ? 'Decrease' : 'Increase',
    ),
  );

  @override
  Widget build(BuildContext context) {
    final touchStepper = _touch && widget.stepper;
    final foreground = _focused
        ? FocusTheme.solidFocusForeground
        : AppColorScheme.onSurface.withValues(
            alpha: widget.dimmed ? 0.5 : 0.85,
          );
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowLeft) {
          widget.onStep(-1, false);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          widget.onStep(1, false);
          return KeyEventResult.handled;
        }
        if (key.isSelectKey) {
          // Only a fresh press steps; a held key's repeats do not.
          if (event is KeyDownEvent &&
              DateTime.now().difference(_born) > _settle) {
            widget.onStep(1, true);
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: touchStepper ? null : () => widget.onStep(1, true),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: touchStepper ? 6 : 14,
          ),
          decoration: FocusTheme.solidFocusDecoration(
            active: _focused,
            radius: 22,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (touchStepper)
                    _stepButton(Icons.remove_rounded, -1, foreground),
                  Text(
                    widget.value,
                    style: TextStyle(
                      color: foreground.withValues(alpha: _focused ? 0.8 : 0.7),
                      fontSize: 15,
                    ),
                  ),
                  if (touchStepper)
                    _stepButton(Icons.add_rounded, 1, foreground),
                ],
              ),
              if (widget.slider case final slider?) ...[
                SizedBox(height: touchStepper ? 2 : 10),
                _touch && widget.onSlide != null
                    ? _DraggableTrack(
                        onSlide: widget.onSlide!,
                        child: _SliderTrack(
                          value: slider.value,
                          origin: slider.origin,
                          color: foreground,
                          focused: _focused,
                          dimmed: widget.dimmed,
                        ),
                      )
                    : _SliderTrack(
                        value: slider.value,
                        origin: slider.origin,
                        color: foreground,
                        focused: _focused,
                        dimmed: widget.dimmed,
                      ),
                if (touchStepper) const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Turns taps and horizontal drags on a [_SliderTrack] into fractions of its
/// width. The hit area is taller than the track so a finger finds it.
class _DraggableTrack extends StatelessWidget {
  const _DraggableTrack({required this.onSlide, required this.child});

  final void Function(double fraction) onSlide;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      void at(Offset local) => onSlide(local.dx / constraints.maxWidth);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => at(d.localPosition),
        onHorizontalDragStart: (d) => at(d.localPosition),
        onHorizontalDragUpdate: (d) => at(d.localPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: child,
        ),
      );
    },
  );
}

/// A thin track with a round thumb at [value], filled from [origin], both as
/// fractions of the width.
class _SliderTrack extends StatelessWidget {
  const _SliderTrack({
    required this.value,
    required this.origin,
    required this.color,
    required this.focused,
    required this.dimmed,
  });

  final double value;
  final double origin;
  final Color color;
  final bool focused;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    const thumb = 12.0;
    final alpha = dimmed ? 0.35 : 1.0;
    return SizedBox(
      height: thumb,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth - thumb;
          final at = width * value.clamp(0.0, 1.0);
          final from = width * origin.clamp(0.0, 1.0);
          return Stack(
            children: [
              Positioned(
                left: thumb / 2,
                right: thumb / 2,
                top: (thumb - 4) / 2,
                height: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18 * alpha),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Positioned(
                left: thumb / 2 + (at < from ? at : from),
                width: (at - from).abs(),
                top: (thumb - 4) / 2,
                height: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.8 * alpha),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Positioned(
                left: at,
                top: 0,
                width: thumb,
                height: thumb,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: alpha),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
