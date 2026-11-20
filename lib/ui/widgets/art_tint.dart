import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../util/image_fetch_priority.dart';
import 'image_source.dart';

/// The colour a page takes from its art, as Plex's TV app washes the page
/// behind its text: a dark, saturated version of the picture's own colour
/// (deep red for a red poster, green for a pitch), so the text sits on the
/// art's colour rather than on black.
class ArtTint {
  ArtTint._();

  static const _width = 24;
  static const _height = 14;
  static const _cacheSize = 64;

  static final _cache = <String, Color?>{};
  static final _pending = <String, Future<Color?>>{};

  /// The tint already worked out for [url], or null when it isn't (yet).
  static Color? cached(String url) => _cache[url];

  /// The tint for [url]: a tiny decode of the art, read once and remembered.
  /// Null when the art can't be read or has no usable colour.
  static Future<Color?> of(String url) {
    if (_cache.containsKey(url)) return SynchronousFuture(_cache[url]);
    // A block body: an arrow would hand whenComplete the removed future,
    // which is this one, and it would wait on itself forever.
    return _pending[url] ??= _load(url).whenComplete(() {
      _pending.remove(url);
    });
  }

  static Future<Color?> _load(String url) async {
    Color? tint;
    try {
      final provider = offlineAwareImageProvider(
        url,
        maxWidth: _width,
        maxHeight: _height,
        headers: isLocalImagePath(url)
            ? null
            : artworkFetchHeaders(url, ImageFetchPriority.low),
      );
      final image = await _resolve(provider).timeout(const Duration(seconds: 10));
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data != null) tint = tintFromPixels(data.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    } catch (error) {
      debugPrint('ArtTint: no tint: $error');
      tint = null;
    }
    _cache[url] = tint;
    while (_cache.length > _cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return tint;
  }

  static Future<ui.Image> _resolve(ImageProvider provider) {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image.clone());
        info.dispose();
        stream.removeListener(listener);
      },
      onError: (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  /// The tint for RGBA [pixels]: the colours averaged with the vivid ones
  /// counting most (a red eye on grey skin still makes a red page), then
  /// brought to the darkness Plex uses behind its text.
  @visibleForTesting
  static Color? tintFromPixels(Uint8List pixels) {
    var r = 0.0, g = 0.0, b = 0.0, total = 0.0;
    for (var i = 0; i + 3 < pixels.length; i += 4) {
      final pr = pixels[i] / 255, pg = pixels[i + 1] / 255;
      final pb = pixels[i + 2] / 255, pa = pixels[i + 3] / 255;
      if (pa < 0.5) continue;
      final hi = math.max(pr, math.max(pg, pb));
      final lo = math.min(pr, math.min(pg, pb));
      final chroma = hi - lo;
      // Near-black and near-white pixels say little about the art's colour.
      final weight = 0.04 + chroma * chroma * 4 * (hi > 0.08 ? 1 : 0);
      r += pr * weight;
      g += pg * weight;
      b += pb * weight;
      total += weight;
    }
    if (total == 0) return null;
    final hsl = HSLColor.fromColor(
      Color.fromARGB(
        255,
        (r / total * 255).round(),
        (g / total * 255).round(),
        (b / total * 255).round(),
      ),
    );
    return hsl
        .withSaturation((hsl.saturation * 1.15).clamp(0.0, 0.72))
        .withLightness(0.2)
        .toColor();
  }
}

/// Builds [builder] with the tint of [url]'s art, easing from one tint to the
/// next as the art changes. [fallback] stands in until the tint is known and
/// when the art has none.
class ArtTintBuilder extends StatefulWidget {
  final String? url;
  final Color fallback;
  final Widget Function(BuildContext context, Color tint) builder;

  const ArtTintBuilder({
    super.key,
    required this.url,
    required this.fallback,
    required this.builder,
  });

  @override
  State<ArtTintBuilder> createState() => _ArtTintBuilderState();
}

class _ArtTintBuilderState extends State<ArtTintBuilder> {
  Color? _tint;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(ArtTintBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _fetch();
  }

  void _fetch() {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    final known = ArtTint.cached(url);
    if (known != null) {
      _tint = known;
      return;
    }
    ArtTint.of(url).then((tint) {
      if (!mounted || widget.url != url || tint == null) return;
      setState(() => _tint = tint);
    });
  }

  @override
  Widget build(BuildContext context) {
    // A see-through fallback (the glass theme's background is) would let the
    // art show through the fade at its edge, so the page colour is opaque.
    final fallback = widget.fallback.withValues(alpha: 1);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: _tint ?? fallback),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      builder: (context, tint, _) => widget.builder(context, tint ?? fallback),
    );
  }
}
