import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screens/lambent_sample/lambent_sample.dart';
import 'package:moonfin/ui/widgets/lambent_sample_button.dart';

void main() {
  group('LambentSample.order', () {
    test('HDR10 first only for an HDR10 screen with a Main 10 decoder', () {
      expect(LambentSample.order(hdrScreen: true, hevcHdr10: true), [
        LambentSample.hdr10,
        LambentSample.sdr2560,
        LambentSample.sdr1920,
      ]);
      for (final (screen, decoder) in [
        (true, false),
        (false, true),
        (false, false),
      ]) {
        expect(LambentSample.order(hdrScreen: screen, hevcHdr10: decoder), [
          LambentSample.sdr2560,
          LambentSample.sdr1920,
        ], reason: 'screen $screen, decoder $decoder');
      }
    });

    test('every variant is HTTPS on the sample store, the 1080p one last', () {
      final all = LambentSample.order(hdrScreen: true, hevcHdr10: true);
      for (final v in all) {
        expect(Uri.parse(v.url).scheme, 'https');
        expect(v.url, contains('/samples/lambent-sample-v1-'));
      }
      expect(all.where((v) => v.hdr), [LambentSample.hdr10]);
      expect(all.last.width, 1920);
    });

    test('the credit names the film, its maker and its licence', () {
      expect(LambentSample.credit, contains('Sintel'));
      expect(LambentSample.credit, contains('Blender Foundation'));
      expect(LambentSample.credit, contains('CC BY 3.0'));
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
