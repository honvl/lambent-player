import 'package:flutter/foundation.dart';

import '../../../util/platform_detection.dart';

/// One encode of the "See the difference" sample.
@immutable
class LambentSampleVariant {
  const LambentSampleVariant({
    required this.url,
    required this.hdr,
    required this.width,
    required this.height,
  });

  final String url;

  /// HDR10 (PQ, BT.2020): Lambent's AI upscaling and Auto HDR. Otherwise SDR,
  /// the upscaling alone, as Lambent Server sends a screen without HDR.
  final bool hdr;

  final int width;
  final int height;

  double get aspectRatio => width / height;

  String get label => hdr ? 'HDR10 ${width}w' : 'SDR ${width}w';
}

/// A film in the sample, from [start] seconds into it, and its credit.
@immutable
class LambentSampleScene {
  const LambentSampleScene(this.start, this.title, this.credit);

  final double start;
  final String title;

  /// Who made it and its licence: the films' licences (CC BY) ask for the
  /// title, the author and the licence.
  final String credit;
}

/// The "See the difference" sample: 64 seconds of six scenes from Blender's
/// open films (snow, a mountain above the clouds, a sunset city, a storm-lit
/// field, a forest by torchlight, a rocket in the clouds) through Lambent
/// Server's compare, the original on the left and Lambent's picture on the
/// right. Rendered once on an RTX PC by the enhancer, at the 1440p a phone is
/// sent and the 4K a TV is sent, with the compare's original lit to the
/// enhanced half's midtones; the compare's own labels were cropped off and the
/// screen draws plain ones.
abstract final class LambentSample {
  static const _base =
      'https://qgvcfga2gzxqngvw.public.blob.vercel-storage.com/samples';

  static const phoneHdr10 = LambentSampleVariant(
    url: '$_base/lambent-sample-v2-phone-hdr10.mp4',
    hdr: true,
    width: 3432,
    height: 1344,
  );
  static const phoneSdr2560 = LambentSampleVariant(
    url: '$_base/lambent-sample-v2-phone-sdr-2560.mp4',
    hdr: false,
    width: 2560,
    height: 1002,
  );

  /// For a decoder that stops at 1080p.
  static const phoneSdr1920 = LambentSampleVariant(
    url: '$_base/lambent-sample-v2-phone-sdr-1920.mp4',
    hdr: false,
    width: 1920,
    height: 752,
  );

  /// The 4K a TV is sent (3840 wide), for TVs and big screens.
  static const tvHdr10 = LambentSampleVariant(
    url: '$_base/lambent-sample-v2-tv-hdr10.mp4',
    hdr: true,
    width: 3840,
    height: 1496,
  );
  static const tvSdr = LambentSampleVariant(
    url: '$_base/lambent-sample-v2-tv-sdr.mp4',
    hdr: false,
    width: 3840,
    height: 1496,
  );

  static const length = Duration(seconds: 64);

  static const scenes = <LambentSampleScene>[
    LambentSampleScene(
      0,
      'Caminandes 3: Llamigos',
      'Caminandes 3: Llamigos by the Blender Institute, CC BY',
    ),
    LambentSampleScene(11, 'Spring', 'Spring by Blender Studio, CC BY 4.0'),
    LambentSampleScene(
      22,
      'Sintel',
      'Sintel by the Blender Foundation (durian.blender.org), CC BY 3.0',
    ),
    LambentSampleScene(
      33,
      'Cosmos Laundromat',
      'Cosmos Laundromat by the Blender Institute, CC BY 4.0',
    ),
    LambentSampleScene(44, 'Spring', 'Spring by Blender Studio, CC BY 4.0'),
    LambentSampleScene(55, 'Wing It!', 'Wing It! by Blender Studio, CC BY 4.0'),
  ];

  /// Said once under every credit.
  static const changes =
      'Clips from studio.blender.org, shortened, cropped and shown through '
      'Lambent.';

  /// The scene playing at [position] (looping past the end).
  static LambentSampleScene sceneAt(Duration position) {
    final seconds = (position.inMilliseconds % length.inMilliseconds) / 1000.0;
    var current = scenes.first;
    for (final scene in scenes) {
      if (scene.start <= seconds) current = scene;
    }
    return current;
  }

  /// Every film's credit, for a screen that shows them all at once.
  static List<String> get allCredits =>
      {for (final scene in scenes) scene.credit}.toList();

  /// Where the sample can play: Android (a phone, a tablet or a TV) through
  /// the app's Media3 player in its HDR window, and Apple devices (iPhone,
  /// iPad, Apple TV, Mac) through AetherEngine.
  static bool get available =>
      !kIsWeb &&
      (PlatformDetection.isAndroid ||
          PlatformDetection.isApple ||
          PlatformDetection.isAppleTV);

  /// The variants to try, best first. HDR10 only where the screen shows HDR10
  /// and a decoder plays HEVC Main 10 in it; each failure falls to the next.
  /// A TV gets the 4K encodes, then the phone's as a lighter fallback.
  static List<LambentSampleVariant> order({
    required bool hdrScreen,
    required bool hevcHdr10,
    bool bigScreen = false,
  }) {
    final hdr = hdrScreen && hevcHdr10;
    return [
      if (bigScreen) ...[if (hdr) tvHdr10, tvSdr],
      if (hdr) phoneHdr10,
      phoneSdr2560,
      phoneSdr1920,
    ];
  }
}
