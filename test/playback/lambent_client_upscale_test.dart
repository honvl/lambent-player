import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/lambent_device_upscale.dart';
import 'package:moonfin/ui/widgets/playback/enhancement_chip.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';

const _enhanced =
    'http://192.168.1.118:47800/v1/enhanced/plex-694844/index.m3u8'
    '?tv=1&q=4&hdr=1&dv=0&blacks=0&maxh=1080&audio=0';

void main() {
  group('direct play steps', () {
    const direct = 'http://pc:47800/Videos/abc/stream?Static=true';

    test('a paid screen\'s steps go on the URL and read back', () {
      final url = LambentEnhancement.withDeviceSteps(
        direct,
        upscale: 2160,
        lift: true,
      );
      expect(url, '$direct&cup=2160&chdr=1');
      expect(LambentEnhancement.clientUpscaleLines(url), 2160);
      expect(LambentEnhancement.clientLift(url), isTrue);
      expect(LambentEnhancement.isEnhancedUrl(url), isFalse);
    });

    test('an unpaid screen\'s URL stays as it is and asks for nothing', () {
      final url = LambentEnhancement.withDeviceSteps(
        direct,
        upscale: null,
        lift: false,
      );
      expect(url, direct);
      expect(LambentEnhancement.clientSteps(url), isFalse);
    });

    test('other URLs do not carry steps', () {
      const download = 'http://pc:47800/Items/abc/Download?cup=2160&chdr=1';
      expect(LambentEnhancement.clientSteps(download), isFalse);
    });

    test('PlaybackInfo\'s member is read, and absent on an unpaid screen', () {
      final paid = PlaybackMediaSource.fromJson({
        'Id': 'abc',
        'LambentDevice': {'Upscale': 2160, 'Lift': true},
      });
      expect(paid.lambentDeviceUpscale, 2160);
      expect(paid.lambentDeviceLift, isTrue);
      final unpaid = PlaybackMediaSource.fromJson({'Id': 'abc'});
      expect(unpaid.lambentDeviceUpscale, isNull);
      expect(unpaid.lambentDeviceLift, isFalse);
    });

    test('the chip names the work beside Original', () {
      const url = '$direct&chdr=1';
      expect(
        withDeviceUpscale('Original', url, 'Auto HDR'),
        'Original · Auto HDR',
      );
      expect(withDeviceUpscale('Original', direct, 'Auto HDR'), 'Original');
    });
  });

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
          'http://192.168.1.118:47800/Items/i_1/Download?static=true&cup=2160',
        ),
        isNull,
      );
    });
  });

  group('the plan gives the HDR lift to the device', () {
    test('with chdr=1', () {
      expect(LambentEnhancement.clientLift('$_enhanced&chdr=1'), isTrue);
      expect(LambentEnhancement.clientSteps('$_enhanced&chdr=1'), isTrue);
      expect(LambentEnhancement.clientSteps('$_enhanced&cup=2160'), isTrue);
    });

    test('not otherwise', () {
      expect(LambentEnhancement.clientLift(_enhanced), isFalse);
      expect(LambentEnhancement.clientLift('$_enhanced&chdr=0'), isFalse);
      expect(LambentEnhancement.clientSteps(_enhanced), isFalse);
      expect(
        LambentEnhancement.clientLift(
          'http://192.168.1.118:47800/Items/i_1/Download?static=true&chdr=1',
        ),
        isFalse,
      );
    });
  });

  group('the chip', () {
    test('names the HDR lift running on the device', () {
      const sdr =
          'http://192.168.1.118:47800/v1/enhanced/plex-694844/index.m3u8'
          '?tv=1&q=4&hdr=0&dv=0&blacks=0&maxh=1080&audio=0&chdr=1';
      expect(
        withDeviceUpscale(lambentEnhancementLabel(sdr), sdr, 'Auto HDR'),
        '1080p · Auto HDR',
      );
    });

    test('leaves out a step the device found not worth its power', () {
      final url = '$_enhanced&cup=2160';
      expect(
        withDeviceUpscale(
          lambentEnhancementLabel(url),
          url,
          lambentDeviceNotNeeded,
        ),
        '1080p HDR',
      );
    });

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
