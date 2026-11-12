import 'dart:async';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin_native_video/moonfin_native_video.dart';
import 'package:playback_core/playback_core.dart' show RepeatMode;
import 'package:url_launcher/url_launcher.dart';

import '../../../playback/aether_backend.dart';
import '../../../playback/display_hdr_probe.dart';
import '../../../playback/media3_player_backend.dart';
import '../../../util/form_factor.dart';
import '../../../util/platform_detection.dart';
import '../../../util/system_ui.dart';
import '../../navigation/destinations.dart';
import '../../widgets/aether_video_view.dart';
import '../../widgets/lambent_server_setup_card.dart'
    show lambentServerSetupAddress, lambentServerSetupUrl;
import '../../widgets/sign_in_qr_code.dart';
import 'lambent_sample.dart';

/// Plays [LambentSample] full screen, looping, with plain labels over each
/// half, the playing film's credit and where to get Lambent Server. Needs no
/// server. Android plays it through the app's Media3 player (a SurfaceView in
/// the HDR window; a TV switches to 24 Hz from the frame rate given), Apple
/// devices through AetherEngine (HDR on an EDR layer; an Apple TV matches the
/// TV's dynamic range and rate when Match Content is on), each with no
/// enhancement of its own on top.
class LambentSampleScreen extends StatefulWidget {
  const LambentSampleScreen({super.key});

  @override
  State<LambentSampleScreen> createState() => _LambentSampleScreenState();
}

/// The two ways the sample plays.
abstract class _SamplePlayer {
  static _SamplePlayer? create() {
    if (PlatformDetection.isAndroid &&
        GetIt.instance.isRegistered<Media3PlayerBackend>()) {
      return _Media3SamplePlayer(GetIt.instance<Media3PlayerBackend>());
    }
    // isApple leaves out the Apple TV, which uses the same engine.
    if ((PlatformDetection.isApple || PlatformDetection.isAppleTV) &&
        GetIt.instance.isRegistered<AetherBackend>()) {
      return _AetherSamplePlayer(GetIt.instance<AetherBackend>());
    }
    return null;
  }

  Widget view();
  Stream<bool> get playing;
  Stream<Map<String, dynamic>> get errors;
  Stream<Duration> get position;
  Future<bool> screenShowsHdr();
  Future<void> play(LambentSampleVariant variant);
  Future<void> stop();

  /// Anything the player keeps listening to, cancelled with the screen.
  List<StreamSubscription<Object?>> get extraSubscriptions => const [];
}

class _Media3SamplePlayer extends _SamplePlayer {
  _Media3SamplePlayer(this.backend);

  static const _platform = MethodChannel('org.moonfin.androidtv/platform');
  final Media3PlayerBackend backend;

  @override
  Widget view() => const Media3VideoView(fill: Colors.black);

  @override
  Stream<bool> get playing => backend.playingStream;

  @override
  Stream<Map<String, dynamic>> get errors => backend.errorStream;

  @override
  Stream<Duration> get position => backend.positionStream;

  /// A TV was probed at launch; a phone isn't, so this asks the display.
  @override
  Future<bool> screenShowsHdr() async {
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

  @override
  Future<void> play(LambentSampleVariant variant) async {
    // An inline preview may have left the shared player quiet.
    await backend.setVolume(100);
    await backend.play(<String, dynamic>{
      'url': variant.url,
      'mediaType': 'video',
      'container': 'mp4',
      // HDR10 says so; the SDR picture is already upscaled, so it isn't
      // marked SDR (that would start the device's own upscaler too).
      if (variant.hdr) 'videoRangeType': 'HDR10',
      // A TV switches its refresh rate only from a rate it is given.
      'videoRealFrameRate': 24.0,
      'videoWidth': variant.width,
      'videoHeight': variant.height,
    });
    await backend.setRepeatMode(RepeatMode.repeatOne);
  }

  @override
  Future<void> stop() async {
    await backend.setRepeatMode(RepeatMode.none);
    // Restores a TV's display mode as well.
    await backend.stop();
  }
}

class _AetherSamplePlayer extends _SamplePlayer {
  _AetherSamplePlayer(this.backend) {
    // AetherEngine has no repeat: start over when the end is reached.
    _loop = backend.completedStream.listen((done) {
      if (!done || _stopped) return;
      unawaited(backend.seekTo(Duration.zero).then((_) => backend.resume()));
    });
  }

  final AetherBackend backend;
  late final StreamSubscription<bool> _loop;
  bool _stopped = false;

  @override
  Widget view() => const AetherVideoView(zoomMode: 'fit');

  @override
  Stream<bool> get playing => backend.playingStream;

  @override
  Stream<Map<String, dynamic>> get errors => backend.errorStream;

  @override
  Stream<Duration> get position => backend.positionStream;

  @override
  Future<bool> screenShowsHdr() => AetherBackend.screenShowsHdr();

  @override
  Future<void> play(LambentSampleVariant variant) async {
    await backend.setVolume(100);
    await backend.play(<String, dynamic>{
      'url': variant.url,
      'mediaType': 'video',
      'noClientEnhancement': true,
    });
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    await backend.stopAndResetDisplay();
  }

  @override
  List<StreamSubscription<Object?>> get extraSubscriptions => [_loop];
}

class _LambentSampleScreenState extends State<LambentSampleScreen>
    with ImmersiveSystemUi {
  static const _openTimeout = Duration(seconds: 20);

  final _SamplePlayer? _player = _SamplePlayer.create();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _focus = FocusNode(debugLabel: 'lambent-sample');
  List<LambentSampleVariant> _order = const [];
  int _index = -1;
  bool _playing = false;
  bool _failed = false;
  bool _phoneLocked = false;
  bool _disposed = false;
  LambentSampleScene _scene = LambentSample.scenes.first;

  LambentSampleVariant? get _current =>
      _index >= 0 && _index < _order.length ? _order[_index] : null;

  @override
  void initState() {
    super.initState();
    setImmersive(true);
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    // A phone shows the wide picture sideways; a tablet plays the way it's held.
    if (!PlatformDetection.isTV &&
        view != null &&
        FormFactor.ofView(view).isPhone) {
      _phoneLocked = true;
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    final player = _player;
    if (player == null) {
      _failed = true;
      return;
    }
    _subscriptions
      ..add(
        player.errors.listen(
          (e) => _fail(_index, '${e['kind'] ?? e['errorCodeName'] ?? e}'),
        ),
      )
      ..add(
        player.playing.listen((playing) {
          if (playing && !_playing && mounted) {
            setState(() => _playing = true);
            _showChrome();
          }
        }),
      )
      ..add(
        player.position.listen((position) {
          final scene = LambentSample.sceneAt(position);
          if (!identical(scene, _scene) && mounted) {
            setState(() => _scene = scene);
          }
        }),
      )
      ..addAll(player.extraSubscriptions);
    // The platform view must exist before the player is pointed at it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final player = _player;
    if (player == null) return;
    final hdrScreen = await player.screenShowsHdr();
    if (_disposed) return;
    // Every Apple device this runs on decodes HEVC Main 10; whether its
    // screen shows HDR is the question there.
    final hevcHdr10 = PlatformDetection.isApple || PlatformDetection.isAppleTV
        ? true
        : PlatformDetection.supportsHevcHdr10;
    _order = LambentSample.order(
      hdrScreen: hdrScreen,
      hevcHdr10: hevcHdr10,
      bigScreen: PlatformDetection.isTV || PlatformDetection.isMacOS,
    );
    debugPrint(
      '[LambentSample] HDR screen $hdrScreen, HEVC Main 10 decoder '
      '$hevcHdr10: trying ${_order.map((v) => v.label).join(', ')}',
    );
    await _next();
  }

  /// Variant [index] stopped (the player's error, or a call that threw or
  /// timed out): move to the next one. A failure is counted once, and one
  /// reported for a variant already left behind is ignored.
  void _fail(int index, String why) {
    if (index != _index || !_failures.add(index)) return;
    debugPrint('[LambentSample] ${_current?.label} failed: $why');
    unawaited(_next());
  }

  final _failures = <int>{};

  /// Plays the next variant, the first one to begin with. Out of variants,
  /// says so.
  Future<void> _next() async {
    final player = _player;
    if (_disposed || player == null || _failed) return;
    _index++;
    final variant = _current;
    if (variant == null) {
      if (mounted) setState(() => _failed = true);
      unawaited(player.stop());
      return;
    }
    if (mounted) setState(() => _playing = false);
    final opened = _index;
    try {
      await player.play(variant).timeout(_openTimeout);
      debugPrint('[LambentSample] playing ${variant.label}');
    } catch (error) {
      _fail(opened, '$error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _chromeTimer?.cancel();
    _focus.dispose();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    unawaited(_player?.stop());
    if (_phoneLocked) SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  void _close() {
    debugPrint('[LambentSample] back');
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(Destinations.serverSelect);
    }
  }

  /// The back button and the caption, until the picture has been watched a
  /// moment; a tap (or any key on a remote) shows them again.
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
    final aspect = (_current ?? LambentSample.phoneHdr10).aspectRatio;
    final tv = PlatformDetection.isTV;
    // A remote has no pointer: the screen takes the keys, shows the caption
    // on any of them and leaves Back to the route.
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent) _showChrome();
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            // The picture as BoxFit.contain places it: full width on a wide
            // screen, with bars above and below.
            final videoW = w / h > aspect ? h * aspect : w;
            final videoH = videoW / aspect;
            final left = (w - videoW) / 2;
            final top = (h - videoH) / 2;
            final labelSize = (videoH * 0.045).clamp(12.0, tv ? 26.0 : 18.0);
            return Stack(
              children: [
                if (_player != null) Positioned.fill(child: _player.view()),
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
                // A remote's Back closes it; a touch screen gets a button.
                if (!tv)
                  _fading(
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
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
                        padding: EdgeInsets.fromLTRB(
                          tv ? 48 : 16,
                          0,
                          tv ? 48 : 16,
                          tv ? 32 : 10,
                        ),
                        child: _Footer(hdr: hdr, scene: _scene, tv: tv),
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

/// What the picture shows, the playing film's credit, and where to get the
/// server: a button on a touch screen, the address and a QR code on a TV.
class _Footer extends StatelessWidget {
  const _Footer({required this.hdr, required this.scene, required this.tv});

  final bool hdr;
  final LambentSampleScene scene;
  final bool tv;

  @override
  Widget build(BuildContext context) {
    final caption = hdr
        ? 'Right: Lambent Server on a PC upscales the film to this screen and '
              'turns it into HDR as it plays. Left: the film as it is.'
        : 'Right: Lambent Server on a PC upscales the film to this screen as '
              'it plays. Left: the film as it is.';
    final scale = tv ? 1.4 : 1.0;
    final getServer = tv
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Get Lambent Server',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 14 * scale,
                    ),
                  ),
                  Text(
                    lambentServerSetupAddress,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16 * scale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              const ExcludeSemantics(
                child: SignInQrCode(data: lambentServerSetupUrl, size: 88),
              ),
            ],
          )
        : FilledButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(lambentServerSetupUrl),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Get Lambent Server'),
          );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14 * scale),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          14 * scale,
          8 * scale,
          8 * scale,
          8 * scale,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    caption,
                    style: TextStyle(color: Colors.white, fontSize: 13 * scale),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${scene.credit}. ${LambentSample.changes}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 11 * scale,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            getServer,
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
