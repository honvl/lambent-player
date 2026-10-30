import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

const _url =
    'http://192.168.1.118:47800/v1/enhanced/plex-694844/index.m3u8'
    '?tv=1&q=4&hdr=1&dv=1&blacks=1&maxh=2160&audio=0&start=60.000';

void main() {
  tearDown(() => LambentEnhancement.overrides = LambentEnhancement.none);

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
