import 'package:flutter/foundation.dart';

import '../../../util/platform_detection.dart';

/// One encode of the "See the difference" sample.
@immutable
class LambentSampleVariant {
  const LambentSampleVariant({
    required this.url,
    required this.hdr,
    required this.width,
  });

  final String url;

  /// HDR10 (PQ, BT.2020): Lambent's AI upscaling and Auto HDR. Otherwise SDR,
  /// the upscaling alone, as Lambent Server sends a screen without HDR.
  final bool hdr;

  /// Picture width in pixels, for the log.
  final int width;
}

/// The "See the difference" sample: a clip of Sintel through Lambent Server's
/// compare, the original on the left and Lambent's picture on the right,
/// rendered once on an RTX PC (the installed enhancer, at the 1440p a phone is
/// sent) so someone without a PC sees what Enhance does. The compare's own
/// labels were cropped off; the screen draws plain ones.
abstract final class LambentSample {
  static const _base =
      'https://qgvcfga2gzxqngvw.public.blob.vercel-storage.com/samples';

  static const hdr10 = LambentSampleVariant(
    url: '$_base/lambent-sample-v1-hdr10.mp4',
    hdr: true,
    width: 3376,
  );
  static const sdr2560 = LambentSampleVariant(
    url: '$_base/lambent-sample-v1-sdr-2560.mp4',
    hdr: false,
    width: 2560,
  );

  /// For a decoder that stops at 1080p.
  static const sdr1920 = LambentSampleVariant(
    url: '$_base/lambent-sample-v1-sdr-1920.mp4',
    hdr: false,
    width: 1920,
  );

  /// Width over height of every variant's picture (3376 x 1344).
  static const aspectRatio = 3376 / 1344;

  /// Sintel's licence (CC BY 3.0) asks for the title, the author, the licence
  /// and a note that it was changed.
  static const credit =
      'Sintel by the Blender Foundation (durian.blender.org), CC BY 3.0. '
      'Clip shortened and shown through Lambent.';

  /// Where the sample can play: an Android phone or tablet, through the app's
  /// Media3 player and its HDR window. An Android TV would first have to
  /// switch the TV to HDR, which only the real player does.
  static bool get available =>
      !kIsWeb && PlatformDetection.isAndroid && !PlatformDetection.isTV;

  /// The variants to try, best first. HDR10 only where the screen shows HDR10
  /// and a decoder plays HEVC Main 10 in it; each failure falls to the next.
  static List<LambentSampleVariant> order({
    required bool hdrScreen,
    required bool hevcHdr10,
  }) => [if (hdrScreen && hevcHdr10) hdr10, sdr2560, sdr1920];
}
