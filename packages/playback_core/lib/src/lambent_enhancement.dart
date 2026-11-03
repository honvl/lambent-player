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
    this.compare,
    this.wideColour,
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

  /// Split screen: the left half is the original, as this screen would play
  /// it without the PC, and the right half is enhanced.
  final bool? compare;

  /// Wide colour, 0 (off) to 100: how far vivid colours are pushed from SDR's
  /// range toward the wider P3 range of graded HDR; skin, greys and soft
  /// colours stay. RTX HDR only. Lambent Server starts at 100; the URL names
  /// it (`gamut`) only when it is on, so an HDR stream that has the picture
  /// controls and no `gamut` offers it at 0 (off).
  final int? wideColour;

  static const none = LambentEnhancement();

  /// The viewer's choices for this session. Null fields leave the server's own
  /// offer alone.
  static LambentEnhancement overrides = none;

  /// True plays Plex's own file instead of the enhanced stream: the
  /// PlaybackInfo request goes out with `EnableTranscoding: false`, which
  /// Lambent Server answers with direct play.
  static bool enhancementOff = false;

  /// The server's household has neither Lambent Enhance nor a trial running:
  /// the PC may enhance only next to the original, so every enhanced stream
  /// is a compare (`cmp=1`), and PlaybackInfo says so (`Lambent.Compare`).
  static bool compareOnly = false;

  /// This screen's own defaults, sent as PlaybackInfo's `Lambent` object
  /// (`RtxHdr`, `DeepenBlacks`, `DolbyVision`, `Saturation`, `Contrast`,
  /// `Brightness`, `Peak`, `Hue`, `Gamut`). A member left out follows the
  /// server.
  static Map<String, Object> screenDefaults = const {};

  /// [body] with this screen's choices added, for the PlaybackInfo request
  /// playback starts from. `LambentPlay` tells Lambent Server it is about to
  /// play (not a detail page asking), so the PC starts making the stream while
  /// the TV switches its display mode.
  static Map<String, dynamic> decoratePlaybackInfo(Map<String, dynamic> body) {
    body['LambentPlay'] = true;
    if (enhancementOff) body['EnableTranscoding'] = false;
    final lambent = {...screenDefaults, if (compareOnly) 'Compare': true};
    if (lambent.isNotEmpty) body['Lambent'] = lambent;
    return body;
  }

  static const _path = '/v1/enhanced/';

  static const qualityRange = (min: 1, max: 4);
  static const saturationRange = (min: 0, max: 200);
  static const contrastRange = (min: 0, max: 200);
  static const middleGrayRange = (min: 10, max: 100);
  static const peakRange = (min: 400, max: 1400);
  static const hueRange = (min: -30, max: 30);
  static const wideColourRange = (min: 0, max: 100);

  static bool isEnhancedUrl(String? url) {
    if (url == null) return false;
    final uri = Uri.tryParse(url);
    return uri != null && uri.path.contains(_path);
  }

  /// The plan's step for this device (docs/MONETIZATION.md 5.1 in Lambent):
  /// upscale here, to at most this many lines (`cup=<lines>` in the enhanced
  /// stream's query, which the server signs). Null when the plan does not ask:
  /// no `cup`, or a stream that is not Lambent's enhanced one. Without Lambent
  /// Enhance or a trial the plan never asks, so the device never upscales; the
  /// client keeps no paywall of its own. The iPad's player
  /// (LambentClientUpscale.swift) reads the same member.
  static int? clientUpscaleLines(String? url) {
    if (!isEnhancedUrl(url)) return null;
    final value = _query(url!).entries
        .where((e) => e.key.toLowerCase() == clientUpscaleKey)
        .map((e) => e.value)
        .lastOrNull;
    final lines = int.tryParse(value?.trim() ?? '');
    return lines != null && lines > 0 ? lines : null;
  }

  static const clientUpscaleKey = 'cup';

  /// The plan's HDR step for this device: lift the SDR picture to HDR10 here
  /// (`chdr=1` in the enhanced stream's query). The iPad's player
  /// (LambentClientUpscale.swift) reads the same member, and lifts only where
  /// the screen has the headroom and Low Power Mode is off.
  static bool clientLift(String? url) {
    if (!isEnhancedUrl(url)) return false;
    final value = _query(url!).entries
        .where((e) => e.key.toLowerCase() == clientLiftKey)
        .map((e) => e.value)
        .lastOrNull;
    return value?.trim() == '1';
  }

  static const clientLiftKey = 'chdr';

  /// The plan gives this device any step of its own (`cup` or `chdr`).
  static bool clientSteps(String? url) =>
      clientUpscaleLines(url) != null || clientLift(url);

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
      compare: flag('cmp'),
      wideColour:
          number('gamut', wideColourRange) ??
          (query.containsKey('mid') ? 0 : null),
    );
  }

  /// [url] with [overrides] written over its query, when it is an enhanced
  /// stream, and compare forced on under [compareOnly]. Anything else comes
  /// back untouched.
  static String applyOverrides(String url) {
    if (!isEnhancedUrl(url) || (overrides == none && !compareOnly)) return url;
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
    // Off is the server's default, so it leaves the query as it was.
    if (o.compare == true) query['cmp'] = '1';
    if (o.compare == false) query.remove('cmp');
    if (compareOnly) query['cmp'] = '1';
    number('gamut', o.wideColour, wideColourRange);
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
    compare: other.compare ?? compare,
    wideColour: other.wideColour ?? wideColour,
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
    compare: compare != base.compare ? compare : null,
    wideColour: wideColour != base.wideColour ? wideColour : null,
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
    bool? compare,
    int? wideColour,
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
    compare: compare ?? this.compare,
    wideColour: wideColour ?? this.wideColour,
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
      other.hue == hue &&
      other.compare == compare &&
      other.wideColour == wideColour;

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
    compare,
    wideColour,
  );

  static Map<String, String> _query(String url) =>
      Uri.tryParse(url)?.queryParameters ?? const {};
}
