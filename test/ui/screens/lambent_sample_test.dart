import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screens/lambent_sample/lambent_sample.dart';
import 'package:moonfin/ui/widgets/lambent_sample_button.dart';

void main() {
  group('LambentSample.order', () {
    test(
      'a phone: HDR10 first only with an HDR10 screen and a Main 10 decoder',
      () {
        expect(LambentSample.order(hdrScreen: true, hevcHdr10: true), [
          LambentSample.phoneHdr10,
          LambentSample.phoneSdr2560,
          LambentSample.phoneSdr1920,
        ]);
        for (final (screen, decoder) in [
          (true, false),
          (false, true),
          (false, false),
        ]) {
          expect(LambentSample.order(hdrScreen: screen, hevcHdr10: decoder), [
            LambentSample.phoneSdr2560,
            LambentSample.phoneSdr1920,
          ], reason: 'screen $screen, decoder $decoder');
        }
      },
    );

    test('a big screen gets the 4K encodes first, then the phone ones', () {
      expect(
        LambentSample.order(hdrScreen: true, hevcHdr10: true, bigScreen: true),
        [
          LambentSample.tvHdr10,
          LambentSample.tvSdr,
          LambentSample.phoneHdr10,
          LambentSample.phoneSdr2560,
          LambentSample.phoneSdr1920,
        ],
      );
      expect(
        LambentSample.order(hdrScreen: false, hevcHdr10: true, bigScreen: true),
        [
          LambentSample.tvSdr,
          LambentSample.phoneSdr2560,
          LambentSample.phoneSdr1920,
        ],
      );
    });

    test('every variant is HTTPS on the sample store, HDR ones marked', () {
      final all = LambentSample.order(
        hdrScreen: true,
        hevcHdr10: true,
        bigScreen: true,
      );
      for (final v in all) {
        expect(Uri.parse(v.url).scheme, 'https');
        expect(v.url, contains('/samples/lambent-sample-v2-'));
        expect(v.url.contains('hdr10'), v.hdr);
        expect(v.aspectRatio, closeTo(2.56, 0.02));
      }
    });
  });

  group('LambentSample scenes', () {
    test('each film is credited while it plays, and the loop starts over', () {
      String at(double s) =>
          LambentSample.sceneAt(Duration(milliseconds: (s * 1000).round()))
              .title;
      expect(at(0), 'Caminandes 3: Llamigos');
      expect(at(10.9), 'Caminandes 3: Llamigos');
      expect(at(11), 'Spring');
      expect(at(25), 'Sintel');
      expect(at(40), 'Cosmos Laundromat');
      expect(at(50), 'Spring');
      expect(at(63.9), 'Wing It!');
      expect(at(64.5), 'Caminandes 3: Llamigos');
    });

    test('every credit names a licence', () {
      for (final scene in LambentSample.scenes) {
        expect(scene.credit, contains('CC BY'), reason: scene.title);
      }
      expect(LambentSample.allCredits.length, 5);
    });
  });

  testWidgets('the button shows only where the sample can play', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: LambentSampleButton(foreground: Colors.white)),
      ),
    );
    expect(
      find.text('See the difference'),
      LambentSample.available ? findsOneWidget : findsNothing,
    );
  });
}
