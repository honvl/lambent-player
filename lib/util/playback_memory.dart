import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'device_performance.dart';
import 'platform_detection.dart';

/// While a video plays on an Android TV box, the menus behind it give back the
/// memory they hold: decoded artwork they aren't showing, and most of Skia's GPU
/// cache. A 4K HDR decoder needs hundreds of MB of the same GPU memory, and on a
/// 3 GB Shield the two together left nothing spare, so opening the player's own
/// menu stalled every frame for seconds. Both come back when the last player
/// closes.
///
/// Clearing the cache only frees what no screen is drawing. The screens left
/// mounted under the player keep their images until ArtworkBound drops them.
class PlaybackMemory {
  PlaybackMemory._();

  static int _players = 0;
  static int? _artworkBytes;

  static bool get _applies => PlatformDetection.isTV && PlatformDetection.isAndroid;

  static void enter() {
    if (!_applies || _players++ > 0) return;
    final cache = PaintingBinding.instance.imageCache;
    _artworkBytes = cache.maximumSizeBytes;
    cache.maximumSizeBytes = artworkBytesDuringPlayback;
    cache.clear();
    _setSkiaCache(skiaCacheBytesDuringPlayback);
  }

  static void leave() {
    if (!_applies || _players == 0 || --_players > 0) return;
    final saved = _artworkBytes;
    if (saved != null) PaintingBinding.instance.imageCache.maximumSizeBytes = saved;
    _artworkBytes = null;
    _setSkiaCache(skiaCacheBytesAfterPlayback);
  }

  static void _setSkiaCache(int? Function(double physicalPixels) budget) {
    final size = WidgetsBinding.instance.platformDispatcher.implicitView?.physicalSize;
    if (size == null) return;
    final bytes = budget(size.width * size.height);
    if (bytes == null) return;
    unawaited(
      SystemChannels.skia
          .invokeMethod<void>('Skia.setResourceCacheMaxBytes', bytes)
          .catchError((_) {}),
    );
  }
}
