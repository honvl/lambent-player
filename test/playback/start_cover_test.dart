import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/playback/start_cover.dart';

void main() {
  test('black from the display switch until just past the first frame', () {
    fakeAsync((async) {
      final cover = StartCover();
      expect(cover.value, isFalse);

      cover.begin();
      async.elapse(const Duration(seconds: 3));
      expect(cover.value, isTrue);

      cover.firstFrame();
      // Still up over the frames the display drops as the picture arrives.
      async.elapse(const Duration(milliseconds: 200));
      expect(cover.value, isTrue);
      async.elapse(const Duration(milliseconds: 100));
      expect(cover.value, isFalse);
    });
  });

  test('a slow start gets its loading animation back', () {
    fakeAsync((async) {
      final cover = StartCover()..begin();
      async.elapse(const Duration(seconds: 5));
      expect(cover.value, isTrue);
      async.elapse(const Duration(seconds: 2));
      expect(cover.value, isFalse);
    });
  });

  test('a start that fails or is abandoned drops the cover at once', () {
    fakeAsync((async) {
      final cover = StartCover()..begin();
      cover.end();
      expect(cover.value, isFalse);
      // The ceiling's timer went with it.
      cover.begin();
      async.elapse(const Duration(seconds: 5));
      expect(cover.value, isTrue);
    });
  });

  test('Dolby Vision is covered for longer past its first frame', () {
    fakeAsync((async) {
      final cover = StartCover()..begin();
      cover.firstFrame(dolbyVision: true);
      // The Shield drops its frames some 0.6 to 0.75 s after the first one.
      async.elapse(const Duration(milliseconds: 900));
      expect(cover.value, isTrue);
      async.elapse(const Duration(milliseconds: 200));
      expect(cover.value, isFalse);
    });
  });

  test('the opening player is black until the switch is decided', () {
    fakeAsync((async) {
      final cover = StartCover()..arm();
      expect(cover.value, isTrue);
      // No switch after all: the loading animation shows.
      cover.end();
      expect(cover.value, isFalse);

      cover
        ..arm()
        ..begin();
      async.elapse(const Duration(seconds: 3));
      expect(
        cover.value,
        isTrue,
        reason: 'a switch outlasts the undecided wait',
      );
    });
  });

  test('an opening player nobody answers gets its controls back', () {
    fakeAsync((async) {
      final cover = StartCover()..arm();
      async.elapse(const Duration(milliseconds: 2100));
      expect(cover.value, isFalse);
    });
  });

  test('a screen that opens after the decision changes nothing', () {
    fakeAsync((async) {
      final cover = StartCover()..end();
      cover.arm();
      expect(cover.value, isFalse);
    });
  });

  test('a first frame with no switch under way changes nothing', () {
    fakeAsync((async) {
      final cover = StartCover()..firstFrame();
      async.elapse(const Duration(seconds: 1));
      expect(cover.value, isFalse);
    });
  });
}
