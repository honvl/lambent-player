import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

const _url =
    'http://192.168.1.118:47800/v1/enhanced/plex-694844/index.m3u8'
    '?tv=1&q=4&hdr=1&dv=1&blacks=1&maxh=2160&audio=0&start=60.000';

void main() {
  tearDown(() {
    LambentEnhancement.overrides = LambentEnhancement.none;
    LambentEnhancement.enhancementOff = false;
    LambentEnhancement.screenDefaults = () => const {};
    LambentEnhancement.compareOnly = false;
    LambentEnhancement.interpolateInsist = false;
    LambentEnhancement.dolbyVisionWithHdr = true;
  });

  group('frame interpolation', () {
    test('a stream is interpolated by its fi, plain or insisted', () {
      expect(LambentEnhancement.interpolated(_url), isFalse);
      expect(LambentEnhancement.interpolated('$_url&fi=1'), isTrue);
      expect(LambentEnhancement.interpolated('$_url&fi=2'), isTrue);
      expect(LambentEnhancement.interpolated('http://h/a.mkv?fi=1'), isFalse);
    });

    test('the stream runs twice the source, or fx tenths of it', () {
      expect(LambentEnhancement.interpolationFactor(_url), 1);
      expect(LambentEnhancement.interpolationFactor('$_url&fi=1'), 2);
      expect(LambentEnhancement.interpolationFactor('$_url&fi=1&fx=25'), 2.5);
      expect(LambentEnhancement.interpolationFactor('$_url&fi=2&fx=24'), 2.4);
      expect(LambentEnhancement.interpolationFactor('$_url&fx=25'), 1);
    });

    test('a field-rate stream is not interpolated', () {
      expect(LambentEnhancement.fieldRate('$_url&di=1'), isTrue);
      expect(LambentEnhancement.interpolated('$_url&di=1'), isFalse);
    });

    test('the insist goes with the screen defaults while it is set', () {
      LambentEnhancement.screenDefaults = () => {'Interpolate2D': true};
      LambentEnhancement.interpolateInsist = true;
      expect(LambentEnhancement.decoratePlaybackInfo({})['Lambent'], {
        'Interpolate2D': true,
        'InterpolateInsist': true,
      });
      LambentEnhancement.interpolateInsist = false;
      expect(LambentEnhancement.decoratePlaybackInfo({})['Lambent'], {
        'Interpolate2D': true,
      });
    });

    test('the overrides keep fi', () {
      LambentEnhancement.overrides = const LambentEnhancement(quality: 2);
      final url = LambentEnhancement.applyOverrides('$_url&fi=2');
      expect(Uri.parse(url).queryParameters['fi'], '2');
    });
  });

  group('compareOnly (no Enhance, no trial)', () {
    test('every enhanced stream is a compare', () {
      LambentEnhancement.compareOnly = true;
      final url = LambentEnhancement.applyOverrides(_url);
      expect(Uri.parse(url).queryParameters['cmp'], '1');
    });

    test('the viewer cannot turn the compare off', () {
      LambentEnhancement.compareOnly = true;
      LambentEnhancement.overrides = const LambentEnhancement(compare: false);
      final url = LambentEnhancement.applyOverrides('$_url&cmp=1');
      expect(Uri.parse(url).queryParameters['cmp'], '1');
    });

    test('tells the server in PlaybackInfo', () {
      LambentEnhancement.compareOnly = true;
      LambentEnhancement.screenDefaults = () => {'RtxHdr': true};
      final body = LambentEnhancement.decoratePlaybackInfo({});
      expect(body['Lambent'], {'RtxHdr': true, 'Compare': true});
    });

    test('leaves the original file alone', () {
      LambentEnhancement.compareOnly = true;
      const original = 'http://host/Videos/1/stream?static=true';
      expect(LambentEnhancement.applyOverrides(original), original);
    });
  });

  group('picture controls on a running stream', () {
    test('lookUri is the stream with look for its file, and the overrides', () {
      LambentEnhancement.overrides = const LambentEnhancement(saturation: 80);
      final uri = LambentEnhancement.lookUri(
        'http://h:47800/v1/enhanced/plex-1~1/master.m3u8?tv=1&sat=100&t=abc',
      )!;
      expect(uri.path, '/v1/enhanced/plex-1~1/look');
      expect(uri.queryParameters['sat'], '80');
      expect(uri.queryParameters['t'], 'abc');
    });

    test('lookUri is null for what is not an enhanced stream', () {
      expect(LambentEnhancement.lookUri('http://h/video.mkv'), isNull);
    });

    test('only the others are a new stream', () {
      const base = LambentEnhancement(quality: 4, saturation: 100, peakNits: 1000);
      expect(base.sameStream(base.copyWith(saturation: 60, contrast: 80, middleGray: 40, hue: 5, wideColour: 0)), isTrue);
      expect(base.sameStream(base.copyWith(peakNits: 800)), isFalse);
      expect(base.sameStream(base.copyWith(quality: 2)), isFalse);
      expect(base.withLookOf(base.copyWith(saturation: 60, peakNits: 800)).peakNits, 1000);
      expect(base.withLookOf(base.copyWith(saturation: 60)).saturation, 60);
    });
  });

  group('HDR strength', () {
    test('only a server that names it offers it', () {
      expect(LambentEnhancement.fromUrl(_url).hdrStrength, isNull);
      expect(LambentEnhancement.fromUrl('$_url&str=100').hdrStrength, 100);
      expect(LambentEnhancement.fromUrl('$_url&str=400').hdrStrength, 100);
    });

    test('an override reaches only a stream whose server has it', () {
      LambentEnhancement.overrides = const LambentEnhancement(hdrStrength: 40);
      expect(
        LambentEnhancement.fromUrl(
          LambentEnhancement.applyOverrides('$_url&str=100'),
        ).hdrStrength,
        40,
      );
      expect(
        Uri.parse(LambentEnhancement.applyOverrides(_url)).queryParameters,
        isNot(contains('str')),
      );
    });

    test('changes on a running stream', () {
      const base = LambentEnhancement(hdrStrength: 100);
      expect(base.sameStream(base.copyWith(hdrStrength: 40)), isTrue);
      expect(base.withLookOf(base.copyWith(hdrStrength: 40)).hdrStrength, 40);
      expect(base.copyWith(hdrStrength: 40).changesFrom(base).hdrStrength, 40);
    });
  });

  group('decoratePlaybackInfo', () {
    test('only marks the request as playback by default', () {
      expect(
        LambentEnhancement.decoratePlaybackInfo({'EnableTranscoding': true}),
        {'EnableTranscoding': true, 'LambentPlay': true},
      );
    });

    test('asks for direct play when enhancement is off', () {
      LambentEnhancement.enhancementOff = true;
      final body = LambentEnhancement.decoratePlaybackInfo({
        'EnableTranscoding': true,
      });
      expect(body['EnableTranscoding'], false);
    });

    test('sends the screen defaults as the Lambent object', () {
      LambentEnhancement.screenDefaults = () => {'DolbyVision': false, 'Saturation': 115};
      final body = LambentEnhancement.decoratePlaybackInfo({});
      expect(body['Lambent'], {'DolbyVision': false, 'Saturation': 115});
    });
  });

  group('LambentEnhancement.fromUrl', () {
    test('reads the settings the URL names', () {
      final e = LambentEnhancement.fromUrl(_url);
      expect(e.quality, 4);
      expect(e.hdr, true);
      expect(e.dolbyVision, true);
      expect(e.deepenBlacks, true);
    });

    test('leaves a setting the URL does not name null', () {
      final e = LambentEnhancement.fromUrl(_url);
      expect(e.saturation, isNull);
      expect(e.contrast, isNull);
      expect(e.hue, isNull);
    });

    test('reads and clamps the picture settings', () {
      final e = LambentEnhancement.fromUrl(
        '$_url&sat=250&con=90&mid=50&peak=556&hue=-45',
      );
      expect(e.saturation, 200);
      expect(e.contrast, 90);
      expect(e.middleGray, 50);
      expect(e.peakNits, 556);
      expect(e.hue, -30);
    });

    test('offers wide colour at 0 on a stream with the picture controls', () {
      expect(LambentEnhancement.fromUrl(_url).wideColour, isNull);
      expect(LambentEnhancement.fromUrl('$_url&mid=50').wideColour, 0);
      expect(LambentEnhancement.fromUrl('$_url&mid=50&gamut=150').wideColour, 100);
    });

    test('writes wide colour as gamut', () {
      LambentEnhancement.overrides = const LambentEnhancement(wideColour: 50);
      final out = Uri.parse(LambentEnhancement.applyOverrides(_url));
      expect(out.queryParameters['gamut'], '50');
    });
  });

  group('LambentEnhancement.applyOverrides', () {
    test('leaves a URL alone when nothing is overridden', () {
      expect(LambentEnhancement.applyOverrides(_url), _url);
    });

    test('leaves a URL that is not enhanced alone', () {
      LambentEnhancement.overrides = const LambentEnhancement(hdr: false);
      const other = 'http://server/Videos/1/stream.mkv?static=true&hdr=1';
      expect(LambentEnhancement.applyOverrides(other), other);
    });

    test('writes only the fields that were overridden', () {
      LambentEnhancement.overrides = const LambentEnhancement(
        quality: 2,
        deepenBlacks: false,
      );
      final out = Uri.parse(LambentEnhancement.applyOverrides(_url));
      expect(out.queryParameters['q'], '2');
      expect(out.queryParameters['blacks'], '0');
      expect(out.queryParameters['hdr'], '1');
      expect(out.queryParameters['dv'], '1');
      expect(out.queryParameters['maxh'], '2160');
      expect(out.queryParameters['start'], '60.000');
      expect(out.path, '/v1/enhanced/plex-694844/index.m3u8');
    });

    test('turns Dolby Vision off with HDR', () {
      LambentEnhancement.overrides = const LambentEnhancement(hdr: false);
      final out = Uri.parse(LambentEnhancement.applyOverrides(_url));
      expect(out.queryParameters['hdr'], '0');
      expect(out.queryParameters['dv'], '0');
    });

    test('adds a picture setting the server did not offer', () {
      LambentEnhancement.overrides = const LambentEnhancement(
        saturation: 120,
        hue: 5,
      );
      final out = Uri.parse(LambentEnhancement.applyOverrides(_url));
      expect(out.queryParameters['sat'], '120');
      expect(out.queryParameters['hue'], '5');
    });

    test('turns compare on and off', () {
      LambentEnhancement.overrides = const LambentEnhancement(compare: true);
      final on = LambentEnhancement.applyOverrides(_url);
      expect(Uri.parse(on).queryParameters['cmp'], '1');
      expect(LambentEnhancement.fromUrl(on).compare, true);
      LambentEnhancement.overrides = const LambentEnhancement(compare: false);
      final off = Uri.parse(LambentEnhancement.applyOverrides(on));
      expect(off.queryParameters.containsKey('cmp'), false);
    });

    test('clamps what it writes', () {
      LambentEnhancement.overrides = const LambentEnhancement(
        quality: 9,
        saturation: -5,
      );
      final out = Uri.parse(LambentEnhancement.applyOverrides(_url));
      expect(out.queryParameters['q'], '4');
      expect(out.queryParameters['sat'], '0');
    });
  });

  group('Dolby Vision with HDR', () {
    const sdr =
        'http://192.168.1.118:47800/v1/enhanced/plex-694844/index.m3u8'
        '?tv=1&q=4&hdr=0&dv=0&blacks=1&sat=100&str=100';

    test('HDR turned on over an SDR offer brings Dolby Vision', () {
      LambentEnhancement.overrides = const LambentEnhancement(hdr: true);
      final q = Uri.parse(LambentEnhancement.applyOverrides(sdr)).queryParameters;
      expect(q['hdr'], '1');
      expect(q['dv'], '1');
    });

    test('but not when the viewer turned Dolby Vision off, or in a browser', () {
      LambentEnhancement.overrides = const LambentEnhancement(hdr: true, dolbyVision: false);
      expect(Uri.parse(LambentEnhancement.applyOverrides(sdr)).queryParameters['dv'], '0');
      LambentEnhancement.overrides = const LambentEnhancement(hdr: true);
      LambentEnhancement.dolbyVisionWithHdr = false;
      expect(Uri.parse(LambentEnhancement.applyOverrides(sdr)).queryParameters['dv'], '0');
    });

    test('an HDR offer keeps the server\'s Dolby Vision', () {
      LambentEnhancement.overrides = const LambentEnhancement(saturation: 110);
      expect(Uri.parse(LambentEnhancement.applyOverrides('${_url.replaceFirst('dv=1', 'dv=0')}&sat=100')).queryParameters['dv'], '0');
    });
  });

  group('changesFrom and merge', () {
    test('changesFrom keeps only what differs', () {
      const base = LambentEnhancement(quality: 4, hdr: true, saturation: 100);
      const chosen = LambentEnhancement(quality: 4, hdr: false, saturation: 110);
      final diff = chosen.changesFrom(base);
      expect(diff.quality, isNull);
      expect(diff.hdr, false);
      expect(diff.saturation, 110);
    });

    test('merge lets the newer choice win and keeps the rest', () {
      const older = LambentEnhancement(quality: 2, hue: 5);
      const newer = LambentEnhancement(quality: 3);
      final merged = older.merge(newer);
      expect(merged.quality, 3);
      expect(merged.hue, 5);
    });
  });
}
