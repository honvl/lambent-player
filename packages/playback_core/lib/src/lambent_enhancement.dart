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
    this.hdrStrength,
  });

  /// RTX Video upscaling quality, 1 (fastest) to 4 (best).
  final int? quality;

  /// HDR: the PC makes the SDR picture HDR10, with the model it chooses for
  /// its speed (Lambent's HDR network, else NVIDIA's TrueHDR).
  final bool? hdr;

  /// Dolby Vision profile 8.1 on top of HDR. Only meaningful with [hdr].
  final bool? dolbyVision;

  /// Bends the dark end of the picture so near-black lands on black.
  final bool? deepenBlacks;

  /// Colour saturation, 0 to 200 (100 is neutral).
  final int? saturation;

  /// Contrast, 0 to 200 (100 is neutral). NVIDIA's HDR model only.
  final int? contrast;

  /// Middle grey in nits: how bright the picture sits. NVIDIA's HDR model only.
  final int? middleGray;

  /// The brightest highlight in nits. HDR only.
  final int? peakNits;

  /// Hue rotation in degrees, -30 to 30 (0 is neutral).
  final int? hue;

  /// Split screen: the left half is the original, as this screen would play
  /// it without the PC, and the right half is enhanced.
  final bool? compare;

  /// Wide colour, 0 (off) to 100: how far vivid colours are pushed from SDR's
  /// range toward the wider P3 range of graded HDR; skin, greys and soft
  /// colours stay. NVIDIA's HDR model only. Lambent Server starts at 100; the URL names
  /// it (`gamut`) only when it is on, so an HDR stream that has the picture
  /// controls and no `gamut` offers it at 0 (off).
  final int? wideColour;

  /// How far toward its peak HDR lifts the picture, 0 to 100. Midtones
  /// hardly move and the top end comes down. A server without the control does
  /// not name it (`str`).
  final int? hdrStrength;

  static const none = LambentEnhancement();

  /// HDR the viewer turns on brings Dolby Vision with it (the owner's choice,
  /// 2026-11-08). Off in a browser, which has no Dolby Vision.
  static bool dolbyVisionWithHdr = true;

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
  /// `Brightness`, `Peak`, `Hue`, `Gamut`, `LosslessAudio`,
  /// `PassthroughAudio`, `Interpolate2D`). A member left out follows the
  /// server.
  ///
  /// A function, read when playback starts: what the sound route can take is
  /// only known once the platform's probe has answered, and it can change.
  static Map<String, Object> Function() screenDefaults = () => const {};

  /// The viewer has just turned frame interpolation on for the title playing:
  /// the reopen that follows says so (`InterpolateInsist`), and Lambent Server
  /// puts the doubled rate before upscaling for that play (`fi=2`). The player
  /// sets it around that one reopen; later plays send `Interpolate2D` alone.
  static bool interpolateInsist = false;

  /// [body] with this screen's choices added, for the PlaybackInfo request
  /// playback starts from. `LambentPlay` tells Lambent Server it is about to
  /// play (not a detail page asking), so the PC starts making the stream while
  /// the TV switches its display mode.
  static Map<String, dynamic> decoratePlaybackInfo(Map<String, dynamic> body) {
    body['LambentPlay'] = true;
    if (enhancementOff) body['EnableTranscoding'] = false;
    final lambent = {
      ...screenDefaults(),
      if (compareOnly) 'Compare': true,
      if (interpolateInsist) 'InterpolateInsist': true,
    };
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
  static const hdrStrengthRange = (min: 0, max: 100);

  static bool isEnhancedUrl(String? url) {
    if (url == null) return false;
    final uri = Uri.tryParse(url);
    return uri != null && uri.path.contains(_path);
  }

  /// A Lambent direct-play URL: the file itself, which carries the device's
  /// steps when PlaybackInfo gave them (`LambentDevice`, [withDeviceSteps]).
  static final _directPath = RegExp(r'/Videos/[^/]+/stream(\.\w+)?$');

  static bool _carriesClientSteps(String? url) {
    if (url == null) return false;
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.path.contains(_path) || _directPath.hasMatch(uri.path));
  }

  /// A direct-play [url] with the device's steps from PlaybackInfo's
  /// `LambentDevice` (docs/ENTITLEMENTS.md 6.6 in Lambent), in the keys an
  /// enhanced URL uses. Lambent Server's stream route ignores them.
  static String withDeviceSteps(
    String url, {
    required int? upscale,
    required bool lift,
  }) {
    final steps = [
      if (upscale != null) '$clientUpscaleKey=$upscale',
      if (lift) '$clientLiftKey=1',
    ];
    if (steps.isEmpty) return url;
    return '$url${url.contains('?') ? '&' : '?'}${steps.join('&')}';
  }

  /// The plan's step for this device (docs/MONETIZATION.md 5.1 in Lambent):
  /// upscale here, to at most this many lines (`cup=<lines>` in the enhanced
  /// stream's query, which the server signs). Null when the plan does not ask:
  /// no `cup`, or a stream that is not Lambent's. Without Lambent Enhance or
  /// a trial the plan never asks, and the player's free RAVU-lite takes the
  /// picture instead; the client keeps no paywall of its own. The iPad's and
  /// Apple TV's player (LambentClientUpscale.swift) reads the same member.
  static int? clientUpscaleLines(String? url) {
    if (!_carriesClientSteps(url)) return null;
    final value = _query(url!).entries
        .where((e) => e.key.toLowerCase() == clientUpscaleKey)
        .map((e) => e.value)
        .lastOrNull;
    final lines = int.tryParse(value?.trim() ?? '');
    return lines != null && lines > 0 ? lines : null;
  }

  static const clientUpscaleKey = 'cup';

  /// The plan's HDR step for this device: lift the SDR picture to HDR10 here
  /// (`chdr=1` in the enhanced stream's query). The iPad's and Apple TV's
  /// player (LambentClientUpscale.swift) reads the same member; the iPad lifts
  /// only where the screen has the headroom and Low Power Mode is off.
  static bool clientLift(String? url) {
    if (!_carriesClientSteps(url)) return false;
    final value = _query(url!).entries
        .where((e) => e.key.toLowerCase() == clientLiftKey)
        .map((e) => e.value)
        .lastOrNull;
    return value?.trim() == '1';
  }

  static const clientLiftKey = 'chdr';

  /// The PC makes in-between frames for this stream (`fi=1`, or `fi=2` when the
  /// viewer insisted): it plays faster than the source ([interpolationFactor]),
  /// and PlaybackInfo's video stream already names the faster rate.
  static bool interpolated(String? url) {
    if (!isEnhancedUrl(url)) return false;
    final value = _query(url!)['fi'];
    return value == '1' || value == '2';
  }

  /// An interpolated stream's rate over the source's: twice it, or `fx=`
  /// tenths of it where the server fitted the screen's refresh (`fx=25`: 24
  /// fps made 60). 1 for a stream that isn't interpolated.
  static double interpolationFactor(String? url) {
    if (!interpolated(url)) return 1;
    final tenths = int.tryParse(_query(url!)['fx'] ?? '') ?? 20;
    return tenths.clamp(20, 25) / 10;
  }

  /// An interlaced source's fields made into frames (`di=1`): the stream is at
  /// twice the source's rate already, and nothing is interpolated.
  static bool fieldRate(String? url) =>
      isEnhancedUrl(url) && _query(url!)['di'] == '1';

  /// The highest source rate the PC interpolates (Lambent Server's
  /// `MAX_INTERPOLATED_FPS`), with room for 29.97 and 30.
  static const maxInterpolatedFps = 30.5;

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
      hdrStrength: number('str', hdrStrengthRange),
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
    // Only a stream whose server has the control, or it would refuse the rest.
    if (query.containsKey('str')) number('str', o.hdrStrength, hdrStrengthRange);
    // Dolby Vision rides on HDR, so it is off whenever HDR is, and on with HDR
    // the viewer turned on over a stream the server offered without it.
    final hdrOn = (query['hdr'] ?? '0') == '1';
    final turnedOn = dolbyVisionWithHdr && hdrOn && uri.queryParameters['hdr'] != '1';
    if (o.dolbyVision != null || query.containsKey('dv')) {
      query['dv'] = hdrOn && (o.dolbyVision ?? (turnedOn || query['dv'] == '1')) ? '1' : '0';
    }
    return uri.replace(queryParameters: query).toString();
  }

  /// Where to send [url]'s picture controls, with [overrides] over them, while
  /// the stream plays: the stream's address with `look` for its file. The PC
  /// makes the segments the player has not asked for yet with them.
  static Uri? lookUri(String url) {
    if (!isEnhancedUrl(url)) return null;
    final uri = Uri.parse(applyOverrides(url));
    final file = uri.path.lastIndexOf('/');
    return uri.replace(path: '${uri.path.substring(0, file)}/look');
  }

  /// Whether only the picture controls that change on a running stream differ.
  /// The rest, the peak among them (the stream's HDR10 metadata names it), are
  /// a new stream.
  bool sameStream(LambentEnhancement other) =>
      quality == other.quality &&
      hdr == other.hdr &&
      dolbyVision == other.dolbyVision &&
      deepenBlacks == other.deepenBlacks &&
      peakNits == other.peakNits &&
      compare == other.compare;

  /// This with [other]'s picture controls that change on a running stream.
  LambentEnhancement withLookOf(LambentEnhancement other) => copyWith(
    saturation: other.saturation,
    contrast: other.contrast,
    middleGray: other.middleGray,
    hue: other.hue,
    wideColour: other.wideColour,
    hdrStrength: other.hdrStrength,
  );

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
    hdrStrength: other.hdrStrength ?? hdrStrength,
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
    hdrStrength: hdrStrength != base.hdrStrength ? hdrStrength : null,
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
    int? hdrStrength,
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
    hdrStrength: hdrStrength ?? this.hdrStrength,
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
      other.wideColour == wideColour &&
      other.hdrStrength == hdrStrength;

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
    hdrStrength,
  );

  static Map<String, String> _query(String url) =>
      Uri.tryParse(url)?.queryParameters ?? const {};
}
