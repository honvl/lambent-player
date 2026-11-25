import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/widgets/playback/stall_meter.dart';

Widget _framed(Widget child) => MaterialApp(
  home: Scaffold(
    backgroundColor: Colors.black,
    body: Center(child: SizedBox(width: 300, child: child)),
  ),
);

double _shownOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.descendant(
        of: find.byType(StallFade),
        matching: find.byType(Opacity),
      ),
    )
    .opacity;

void main() {
  group('stallFillFraction', () {
    const position = Duration(minutes: 61);

    test('measures the buffer ahead against what the player waits for', () {
      expect(stallFillFraction(position: position, buffered: position), 0);
      expect(
        stallFillFraction(
          position: position,
          buffered: position + const Duration(milliseconds: 500),
        ),
        0.25,
      );
      expect(
        stallFillFraction(
          position: position,
          buffered: position + stallResumeBuffer,
        ),
        1,
      );
    });

    test('stays within the bar', () {
      // A buffer report from before a seek can sit behind the playhead.
      expect(
        stallFillFraction(
          position: position,
          buffered: position - const Duration(seconds: 30),
        ),
        0,
      );
      expect(
        stallFillFraction(
          position: position,
          buffered: position + const Duration(seconds: 40),
        ),
        1,
      );
    });
  });

  group('StallFade', () {
    Widget fade(bool stalled, {bool suppressed = false}) => _framed(
      Stack(
        alignment: Alignment.center,
        children: [
          const Text('timeline'),
          StallFade(
            stalled: stalled,
            suppressed: suppressed,
            builder: (_) => const StallTrack(position: 0.4, fill: 0.5),
          ),
        ],
      ),
    );

    testWidgets('a stall too short to matter shows nothing', (tester) async {
      await tester.pumpWidget(fade(true));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(StallTrack), findsNothing);

      await tester.pumpWidget(fade(false));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(StallTrack), findsNothing);
    });

    testWidgets('the timeline stays while the stall is drawn over it', (
      tester,
    ) async {
      await tester.pumpWidget(fade(true));
      await tester.pump(StallFade.wait);
      await tester.pump(StallFade.fadeIn);
      await tester.pump();
      expect(find.text('timeline'), findsOneWidget);
      expect(find.byType(StallTrack), findsOneWidget);
      expect(_shownOpacity(tester), 1);
    });

    testWidgets('it lingers after the stall ends, then fades away', (
      tester,
    ) async {
      await tester.pumpWidget(fade(true));
      await tester.pump(StallFade.wait);
      await tester.pump(StallFade.fadeIn);
      await tester.pump();

      await tester.pumpWidget(fade(false));
      await tester.pump(const Duration(milliseconds: 400));
      // A third of the way through, it has barely begun to thin.
      expect(_shownOpacity(tester), greaterThan(0.8));

      await tester.pump(const Duration(milliseconds: 500));
      expect(_shownOpacity(tester), inExclusiveRange(0.05, 0.8));

      await tester.pump(StallFade.fadeOut);
      await tester.pump();
      expect(find.byType(StallTrack), findsNothing);
    });

    testWidgets('it goes at once when something else shows the stall', (
      tester,
    ) async {
      await tester.pumpWidget(fade(true));
      await tester.pump(StallFade.wait);
      await tester.pump(StallFade.fadeIn);
      await tester.pump();
      expect(find.byType(StallTrack), findsOneWidget);

      await tester.pumpWidget(fade(true, suppressed: true));
      await tester.pump();
      expect(find.byType(StallTrack), findsNothing);
    });
  });

  testWidgets('the pill draws its own timeline', (tester) async {
    await tester.pumpWidget(_framed(const StallPill(position: 0.4, fill: 0.2)));
    final track = tester.widget<StallTrack>(find.byType(StallTrack));
    expect(track.standalone, isTrue);
    expect(track.position, 0.4);
    // The sweep never settles, so no pumpAndSettle here.
  });
}
