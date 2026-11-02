import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/widgets/playback/enhancement_chip.dart';
import 'package:playback_core/playback_core.dart';

const _enhanced =
    'http://192.168.1.118:47800/v1/enhanced/plex-694844/index.m3u8'
    '?tv=1&q=4&hdr=1&dv=0&blacks=0&maxh=1080&audio=0';

void main() {
  tearDown(() {
    LambentEnhancement.overrides = LambentEnhancement.none;
    LambentEnhancement.compareOnly = false;
  });

  group('the plan asks for the upscale on the device', () {
    test('with cup', () {
      expect(
        LambentEnhancement.clientUpscaleLines('$_enhanced&cup=2160'),
        2160,
      );
      expect(
        LambentEnhancement.clientUpscaleLines('$_enhanced&CUP=1440'),
        1440,
      );
    });

    test('and the viewer\'s overrides keep it', () {
      LambentEnhancement.overrides = const LambentEnhancement(quality: 2);
      final url = LambentEnhancement.applyOverrides('$_enhanced&cup=2160');
      expect(LambentEnhancement.clientUpscaleLines(url), 2160);
    });
  });

  group('the plan does not ask', () {
    test('without cup (no Enhance and no trial)', () {
      expect(LambentEnhancement.clientUpscaleLines(_enhanced), isNull);
      // The compare-only stream the server gives without Enhance.
      LambentEnhancement.compareOnly = true;
      expect(
        LambentEnhancement.clientUpscaleLines(
          LambentEnhancement.applyOverrides(_enhanced),
        ),
        isNull,
      );
    });

    test('with a cup that is not a line count', () {
      for (final value in ['0', '-2160', 'on', '']) {
        expect(
          LambentEnhancement.clientUpscaleLines('$_enhanced&cup=$value'),
          isNull,
          reason: 'cup=$value',
        );
      }
    });

    test('on a stream that is not Lambent\'s enhanced one', () {
      expect(LambentEnhancement.clientUpscaleLines(null), isNull);
      expect(
        LambentEnhancement.clientUpscaleLines(
          'http://192.168.1.118:47800/Videos/i_1/stream?static=true&cup=2160',
        ),
        isNull,
      );
    });
  });

  group('the chip', () {
    test('names the upscale running on the device', () {
      final url = '$_enhanced&cup=2160';
      expect(
        withDeviceUpscale(lambentEnhancementLabel(url), url, 'AI upscale'),
        '1080p HDR · AI upscale',
      );
      expect(
        withDeviceUpscale(lambentEnhancementLabel(url), url, 'Shader upscale'),
        '1080p HDR · Shader upscale',
      );
    });

    test('says nothing of it until it runs', () {
      final url = '$_enhanced&cup=2160';
      expect(
        withDeviceUpscale(lambentEnhancementLabel(url), url, null),
        '1080p HDR',
      );
    });

    test('ignores a stale upscale when the plan does not ask', () {
      expect(
        withDeviceUpscale(
          lambentEnhancementLabel(_enhanced),
          _enhanced,
          'AI upscale',
        ),
        '1080p HDR',
      );
    });
  });
}
