import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screensaver/screensaver_controller.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:playback_core/playback_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The media bar plays one film's trailer after another for as long as the
/// home screen is up. A trailer someone is watching keeps the screensaver
/// away; an idle home screen still gets it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UserPreferences prefs;
  late PlaybackManager manager;
  const trailer = Duration(minutes: 2, seconds: 30);
  const gap = Duration(seconds: 2);

  setUp(() async {
    PlatformDetection.setTvMode(true);
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);
    manager = PlaybackManager();
  });

  tearDown(() {
    PlatformDetection.setTvMode(false);
    manager.dispose();
  });

  /// Plays trailers back to back, as the media bar does, until the
  /// screensaver comes up (which stops the trailer) or [limit] passes.
  Duration cycleTrailers(
    FakeAsync async,
    ScreensaverController controller,
    Duration limit,
  ) {
    var elapsed = Duration.zero;
    while (elapsed < limit && !controller.visible.value) {
      controller.setMediaBarTrailerActive(true);
      for (var s = 0; s < trailer.inSeconds; s++) {
        async.elapse(const Duration(seconds: 1));
        elapsed += const Duration(seconds: 1);
        if (controller.visible.value) break;
      }
      controller.setMediaBarTrailerActive(false);
      if (controller.visible.value) break;
      async.elapse(gap);
      elapsed += gap;
    }
    return elapsed;
  }

  test('a trailer started just after a key press is not interrupted', () {
    fakeAsync((async) {
      final controller = ScreensaverController(prefs, manager);
      async.elapse(const Duration(minutes: 4));
      controller.notifyInteraction();
      async.elapse(const Duration(seconds: 10));
      controller.setMediaBarTrailerActive(true);
      async.elapse(const Duration(minutes: 7));
      expect(controller.visible.value, isFalse);

      controller.setMediaBarTrailerActive(false);
      async.elapse(const Duration(minutes: 6));
      expect(controller.visible.value, isTrue);
      controller.dispose();
    });
  });

  test('trailers playing one after another on an idle home screen still '
      'give way to the screensaver', () {
    fakeAsync((async) {
      final controller = ScreensaverController(prefs, manager);
      final took = cycleTrailers(async, controller, const Duration(hours: 1));
      expect(controller.visible.value, isTrue);
      // The trailers that began while the app was fresh hold, then one
      // timeout passes after the last of them ends.
      expect(took, lessThan(const Duration(minutes: 14)));
      controller.dispose();
    });
  });

  test('a key press during a trailer makes it hold again', () {
    fakeAsync((async) {
      final controller = ScreensaverController(prefs, manager);
      // A long trailer that began at launch holds until 5:30.
      async.elapse(const Duration(seconds: 10));
      controller.setMediaBarTrailerActive(true);
      async.elapse(const Duration(minutes: 5, seconds: 20));
      controller.setMediaBarTrailerActive(false);
      async.elapse(gap);
      // The next one starts with no key press for over five minutes.
      controller.setMediaBarTrailerActive(true);
      async.elapse(const Duration(minutes: 1));
      controller.notifyInteraction();
      async.elapse(const Duration(minutes: 7));
      expect(controller.visible.value, isFalse);

      controller.setMediaBarTrailerActive(false);
      async.elapse(const Duration(minutes: 6));
      expect(controller.visible.value, isTrue);
      controller.dispose();
    });
  });

  test('after the screensaver is dismissed, the next trailer holds', () {
    fakeAsync((async) {
      final controller = ScreensaverController(prefs, manager);
      async.elapse(const Duration(minutes: 6));
      expect(controller.visible.value, isTrue);
      controller.dismiss();
      async.elapse(const Duration(seconds: 5));
      controller.setMediaBarTrailerActive(true);
      async.elapse(const Duration(minutes: 7));
      expect(controller.visible.value, isFalse);
      controller.dispose();
    });
  });
}
