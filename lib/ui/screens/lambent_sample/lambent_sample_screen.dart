import 'dart:async';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin_native_video/moonfin_native_video.dart';
import 'package:playback_core/playback_core.dart' show RepeatMode;
import 'package:url_launcher/url_launcher.dart';

import '../../../playback/display_hdr_probe.dart';
import '../../../playback/media3_player_backend.dart';
import '../../../util/form_factor.dart';
import '../../../util/platform_detection.dart';
import '../../../util/system_ui.dart';
import '../../widgets/lambent_server_setup_card.dart'
    show lambentServerSetupUrl;
import 'lambent_sample.dart';

/// Plays [LambentSample] full screen, looping, through the app's Media3 player
/// (a SurfaceView in the HDR window, so HDR10 reaches the panel), with plain
/// labels over each half, the film's credit and a link to Lambent Server.
/// Needs no server.
class LambentSampleScreen extends StatefulWidget {
  const LambentSampleScreen({super.key});

  @override
  State<LambentSampleScreen> createState() => _LambentSampleScreenState();
}

class _LambentSampleScreenState extends State<LambentSampleScreen>
    with ImmersiveSystemUi {
  static const _platform = MethodChannel('org.moonfin.androidtv/platform');
  static const _openTimeout = Duration(seconds: 20);

  final Media3PlayerBackend? _backend =
      GetIt.instance.isRegistered<Media3PlayerBackend>()
      ? GetIt.instance<Media3PlayerBackend>()
      : null;

  final _subscriptions = <StreamSubscription<Object?>>[];
  List<LambentSampleVariant> _order = const [];
  int _index = -1;
  bool _playing = false;
  bool _failed = false;
  bool _phoneLocked = false;
  bool _disposed = false;

  LambentSampleVariant? get _current =>
      _index >= 0 && _index < _order.length ? _order[_index] : null;

  @override
  void initState() {
    super.initState();
    setImmersive(true);
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    // A phone shows the wide picture sideways; a tablet plays the way it's held.
    if (view != null && FormFactor.ofView(view).isPhone) {
      _phoneLocked = true;
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    final backend = _backend;
    if (backend == null) {
      _failed = true;
      return;
    }
    _subscriptions
      ..add(
        backend.errorStream.listen(
          (e) => _fail(_index, '${e['kind'] ?? e['errorCodeName'] ?? e}'),
        ),
      )
      ..add(
        backend.playingStream.listen((playing) {
          if (playing && !_playing && mounted) {
            setState(() => _playing = true);
            _showChrome();
          }
        }),
      );
    // The platform view must exist before the player is pointed at it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final hdrScreen = await _screenShowsHdr10();
    if (_disposed) return;
    _order = LambentSample.order(
      hdrScreen: hdrScreen,
      hevcHdr10: PlatformDetection.supportsHevcHdr10,
    );
    debugPrint(
      '[LambentSample] HDR10 screen $hdrScreen, HEVC Main 10 decoder '
      '${PlatformDetection.supportsHevcHdr10}: trying '
      '${_order.map((v) => v.hdr ? 'HDR10' : 'SDR ${v.width}').join(', ')}',
    );
    await _next();
  }

  /// Whether the panel takes HDR10. A phone isn't probed at launch (only an
  /// Android TV is), so this asks the display directly.
  Future<bool> _screenShowsHdr10() async {
    if (PlatformDetection.isTV) return PlatformDetection.supportsHdr10;
    try {
      final raw = await _platform.invokeMethod<Map<dynamic, dynamic>>(
        'displayCapabilities',
        <String, dynamic>{'trigger': 'lambent-sample'},
      );
      if (raw == null) return false;
      final types = DisplayHdrSnapshot.fromMap(
        raw.map((key, value) => MapEntry(key.toString(), value)),
      ).types;
      return types.contains('HDR10') || types.contains('HDR10_PLUS');
    } catch (_) {
      return false;
    }
  }

  /// Variant [index] stopped (the player's error, or a call that threw or
  /// timed out): move to the next one. A failure is counted once, and one
  /// reported for a variant already left behind is ignored.
  void _fail(int index, String why) {
    if (index != _index || !_failures.add(index)) return;
    debugPrint('[LambentSample] ${_label(_current)} failed: $why');
    unawaited(_next());
  }

  final _failures = <int>{};

  /// Plays the next variant, the first one to begin with. Out of variants,
  /// says so.
  Future<void> _next() async {
    final backend = _backend;
    if (_disposed || backend == null || _failed) return;
    _index++;
    final variant = _current;
    if (variant == null) {
      if (mounted) setState(() => _failed = true);
      unawaited(backend.stop());
      return;
    }
    if (mounted) setState(() => _playing = false);
    final opened = _index;
    try {
      // An inline preview may have left the shared player quiet.
      await backend.setVolume(100);
      await backend
          .play(<String, dynamic>{
            'url': variant.url,
            'mediaType': 'video',
            'container': 'mp4',
            // HDR10 says so; the SDR picture is already upscaled, so it isn't
            // marked SDR (that would start the device's own upscaler too).
            if (variant.hdr) 'videoRangeType': 'HDR10',
          })
          .timeout(_openTimeout);
      await backend.setRepeatMode(RepeatMode.repeatOne);
      debugPrint('[LambentSample] playing ${_label(variant)}');
    } catch (error) {
      _fail(opened, '$error');
    }
  }

  static String _label(LambentSampleVariant? v) =>
      v == null ? 'none' : (v.hdr ? 'HDR10' : 'SDR ${v.width}');

  @override
  void dispose() {
    _disposed = true;
    _chromeTimer?.cancel();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    final backend = _backend;
    if (backend != null) {
      unawaited(backend.setRepeatMode(RepeatMode.none));
      unawaited(backend.stop());
    }
    if (_phoneLocked) SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  void _close() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  /// The back button and the caption, until the picture has been watched a
  /// moment; a tap shows them again.
  bool _chrome = true;
  Timer? _chromeTimer;
  static const _chromeFor = Duration(seconds: 6);

  void _showChrome() {
    _chromeTimer?.cancel();
    if (mounted && !_chrome) setState(() => _chrome = true);
    _chromeTimer = Timer(_chromeFor, () {
      if (mounted && _playing) setState(() => _chrome = false);
    });
  }

  Widget _fading(Widget child) => IgnorePointer(
    ignoring: !_chrome,
    child: AnimatedOpacity(
      opacity: _chrome ? 1 : 0,
      duration: const Duration(milliseconds: 300),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hdr = _current?.hdr ?? false;
    return PopScope(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            // The picture as BoxFit.contain places it: full width on a phone
            // held sideways, with bars above and below.
            final videoW = w / h > LambentSample.aspectRatio
                ? h * LambentSample.aspectRatio
                : w;
            final videoH = videoW / LambentSample.aspectRatio;
            final left = (w - videoW) / 2;
            final top = (h - videoH) / 2;
            final labelSize = (videoH * 0.045).clamp(12.0, 18.0);
            return Stack(
              children: [
                const Positioned.fill(
                  child: Media3VideoView(fill: Colors.black),
                ),
                if (_playing) ...[
                  Positioned(
                    top: top + 10,
                    right: w - (left + videoW / 2) + 10,
                    child: _Pill('Original', fontSize: labelSize),
                  ),
                  Positioned(
                    top: top + 10,
                    left: left + videoW / 2 + 10,
                    child: _Pill('Lambent', fontSize: labelSize),
                  ),
                ],
                if (!_playing && !_failed)
                  const Center(child: CircularProgressIndicator()),
                if (_failed)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        "This device couldn't play the sample.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                  ),
                // A tap anywhere brings the back button and the caption back.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _showChrome,
                  ),
                ),
                _fading(
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: _GlassButton(
                          tooltip: 'Back',
                          onPressed: _close,
                          child: const Icon(
                            Icons.chevron_left_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                _fading(
                  SafeArea(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: _Footer(hdr: hdr),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// What the picture shows, the film's credit, and where to get the server.
class _Footer extends StatelessWidget {
  const _Footer({required this.hdr});

  final bool hdr;

  @override
  Widget build(BuildContext context) {
    final caption = hdr
        ? 'Right: Lambent Server on a PC upscales the film to this screen and '
              'turns it into HDR as it plays. Left: the film as it is.'
        : 'Right: Lambent Server on a PC upscales the film to this screen as '
              'it plays. Left: the film as it is.';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    caption,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    LambentSample.credit,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(lambentServerSetupUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Get Lambent Server'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {required this.fontSize});

  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: fontSize * 0.8,
          vertical: fontSize * 0.25,
        ),
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(width: 44, height: 44, child: Center(child: child)),
        ),
      ),
    );
  }
}
