/// What Lambent Server's PC enhancer is asked to do to a stream.
///
/// The server marks an enhanced stream by its URL
/// (`/v1/enhanced/<item>/index.m3u8?q=4&hdr=1&dv=1&blacks=1&sat=100...`), so
/// the settings live in the query. The viewer can change them while watching;
/// [overrides] holds what they chose, and the resolver writes it over whatever
/// the server offered, so the next stream (a reopen, the next episode) keeps it
/// until the app restarts.
///
/// A setting the URL does not name is null: the server does not offer it, and
/// the player leaves its control out.
class LambentEnhancement {
  const LambentEnhancement({
    this.quality,
    this.hdr,
    this.dolbyVision,
    this.deepenBlacks,
    this.saturation,
    this.contrast,
    this.middleGray,
    this.peakNits,
    this.hue,
  });

  /// RTX Video upscaling quality, 1 (fastest) to 4 (best).
  final int? quality;

  /// RTX HDR: tone-maps the SDR picture into HDR10.
  final bool? hdr;

  /// Dolby Vision profile 8.1 on top of RTX HDR. Only meaningful with [hdr].
  final bool? dolbyVision;

  /// Bends the dark end of the picture so near-black lands on black.
  final bool? deepenBlacks;

  /// Colour saturation, 0 to 200 (100 is neutral).
  final int? saturation;

  /// Contrast, 0 to 200 (100 is neutral). RTX HDR only.
  final int? contrast;

  /// Middle grey in nits: how bright the picture sits. RTX HDR only.
  final int? middleGray;

  /// The brightest highlight in nits. RTX HDR only.
  final int? peakNits;

  /// Hue rotation in degrees, -30 to 30 (0 is neutral).
  final int? hue;

  static const none = LambentEnhancement();

  /// The viewer's choices for this session. Null fields leave the server's own
  /// offer alone.
  static LambentEnhancement overrides = none;

  /// True plays Plex's own file instead of the enhanced stream: the
  /// PlaybackInfo request goes out with `EnableTranscoding: false`, which
  /// Lambent Server answers with direct play.
  static bool enhancementOff = false;

  /// This screen's own defaults, sent as PlaybackInfo's `Lambent` object
  /// (`RtxHdr`, `DeepenBlacks`, `DolbyVision`, `Saturation`, `Contrast`,
  /// `Brightness`, `Peak`, `Hue`). A member left out follows the server.
  static Map<String, Object> screenDefaults = const {};

  /// [body] with this screen's choices added, for a PlaybackInfo request.
  static Map<String, dynamic> decoratePlaybackInfo(Map<String, dynamic> body) {
    if (enhancementOff) body['EnableTranscoding'] = false;
    if (screenDefaults.isNotEmpty) body['Lambent'] = screenDefaults;
    return body;
  }

  static const _path = '/v1/enhanced/';

  static const qualityRange = (min: 1, max: 4);
  static const saturationRange = (min: 0, max: 200);
  static const contrastRange = (min: 0, max: 200);
  static const middleGrayRange = (min: 10, max: 100);
  static const peakRange = (min: 400, max: 1400);
  static const hueRange = (min: -30, max: 30);

  static bool isEnhancedUrl(String? url) {
    if (url == null) return false;
    final uri = Uri.tryParse(url);
    return uri != null && uri.path.contains(_path);
  }

  /// The settings [url] carries.
  static LambentEnhancement fromUrl(String url) {
    final query = _query(url);
    bool? flag(String key) {
      final value = query[key];
      if (value == null) return null;
      return value == '1';
    }

    int? number(String key, ({int min, int max}) range) {
      final parsed = int.tryParse(query[key] ?? '');
      return parsed?.clamp(range.min, range.max);
    }

    return LambentEnhancement(
      quality: number('q', qualityRange),
      hdr: flag('hdr'),
      dolbyVision: flag('dv'),
      deepenBlacks: flag('blacks'),
      saturation: number('sat', saturationRange),
      contrast: number('con', contrastRange),
      middleGray: number('mid', middleGrayRange),
      peakNits: number('peak', peakRange),
      hue: number('hue', hueRange),
    );
  }

  /// [url] with [overrides] written over its query, when it is an enhanced
  /// stream. Anything else comes back untouched.
  static String applyOverrides(String url) {
    if (!isEnhancedUrl(url) || overrides == none) return url;
    final uri = Uri.parse(url);
    final query = Map<String, String>.of(uri.queryParameters);
    final o = overrides;
    void number(String key, int? value, ({int min, int max}) range) {
      if (value != null) query[key] = '${value.clamp(range.min, range.max)}';
    }

    number('q', o.quality, qualityRange);
    if (o.hdr != null) query['hdr'] = o.hdr! ? '1' : '0';
    if (o.deepenBlacks != null) query['blacks'] = o.deepenBlacks! ? '1' : '0';
    number('sat', o.saturation, saturationRange);
    number('con', o.contrast, contrastRange);
    number('mid', o.middleGray, middleGrayRange);
    number('peak', o.peakNits, peakRange);
    number('hue', o.hue, hueRange);
    // Dolby Vision rides on RTX HDR, so it is off whenever HDR is.
    final hdrOn = (query['hdr'] ?? '0') == '1';
    if (o.dolbyVision != null || (query.containsKey('dv') && !hdrOn)) {
      query['dv'] = hdrOn && (o.dolbyVision ?? query['dv'] == '1') ? '1' : '0';
    }
    return uri.replace(queryParameters: query).toString();
  }

  /// This with every field [other] names replacing the one here.
  LambentEnhancement merge(LambentEnhancement other) => LambentEnhancement(
    quality: other.quality ?? quality,
    hdr: other.hdr ?? hdr,
    dolbyVision: other.dolbyVision ?? dolbyVision,
    deepenBlacks: other.deepenBlacks ?? deepenBlacks,
    saturation: other.saturation ?? saturation,
    contrast: other.contrast ?? contrast,
    middleGray: other.middleGray ?? middleGray,
    peakNits: other.peakNits ?? peakNits,
    hue: other.hue ?? hue,
  );

  /// Only the fields of this that differ from [base], so pinning a choice
  /// leaves every setting the viewer did not touch following the server.
  LambentEnhancement changesFrom(LambentEnhancement base) => LambentEnhancement(
    quality: quality != base.quality ? quality : null,
    hdr: hdr != base.hdr ? hdr : null,
    dolbyVision: dolbyVision != base.dolbyVision ? dolbyVision : null,
    deepenBlacks: deepenBlacks != base.deepenBlacks ? deepenBlacks : null,
    saturation: saturation != base.saturation ? saturation : null,
    contrast: contrast != base.contrast ? contrast : null,
    middleGray: middleGray != base.middleGray ? middleGray : null,
    peakNits: peakNits != base.peakNits ? peakNits : null,
    hue: hue != base.hue ? hue : null,
  );

  LambentEnhancement copyWith({
    int? quality,
    bool? hdr,
    bool? dolbyVision,
    bool? deepenBlacks,
    int? saturation,
    int? contrast,
    int? middleGray,
    int? peakNits,
    int? hue,
  }) => LambentEnhancement(
    quality: quality ?? this.quality,
    hdr: hdr ?? this.hdr,
    dolbyVision: dolbyVision ?? this.dolbyVision,
    deepenBlacks: deepenBlacks ?? this.deepenBlacks,
    saturation: saturation ?? this.saturation,
    contrast: contrast ?? this.contrast,
    middleGray: middleGray ?? this.middleGray,
    peakNits: peakNits ?? this.peakNits,
    hue: hue ?? this.hue,
  );

  @override
  bool operator ==(Object other) =>
      other is LambentEnhancement &&
      other.quality == quality &&
      other.hdr == hdr &&
      other.dolbyVision == dolbyVision &&
      other.deepenBlacks == deepenBlacks &&
      other.saturation == saturation &&
      other.contrast == contrast &&
      other.middleGray == middleGray &&
      other.peakNits == peakNits &&
      other.hue == hue;

  @override
  int get hashCode => Object.hash(
    quality,
    hdr,
    dolbyVision,
    deepenBlacks,
    saturation,
    contrast,
    middleGray,
    peakNits,
    hue,
  );

  static Map<String, String> _query(String url) =>
      Uri.tryParse(url)?.queryParameters ?? const {};
}
