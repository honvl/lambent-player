import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/widgets/playback/enhancement_panel.dart';
import 'package:playback_core/playback_core.dart';

void main() {
  const current = LambentEnhancement(
    quality: 4,
    hdr: true,
    dolbyVision: true,
    deepenBlacks: false,
    saturation: 100,
  );
  var live = <LambentEnhancement>[];
  var shownNow = 0;

  Future<List<LambentEnhancement>> open(
    WidgetTester tester, {
    LambentEnhancement start = current,
    EnhancementInterpolation? interpolation,
  }) async {
    tester.view.physicalSize = const Size(1920, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final applied = <LambentEnhancement>[];
    live = [];
    shownNow = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showEnhancementPanel(
              context,
              current: start,
              enhanced: true,
              onSetEnhancement: (_) {},
              onApply: applied.add,
              onLive: live.add,
              liveDelay: () => const Duration(seconds: 20),
              onShowLiveNow: () => shownNow++,
              onReset: () {},
              onShowStreamInfo: () {},
              interpolation: interpolation,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return applied;
  }

  testWidgets('no frame interpolation row unless it is offered', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Frame interpolation'), findsNothing);
  });

  testWidgets('frame interpolation turns on when pressed and closes', (
    tester,
  ) async {
    final set = <bool>[];
    await open(
      tester,
      interpolation: (on: false, streamFps: null, onSet: set.add),
    );
    await tester.tap(find.text('Frame interpolation'));
    await tester.pumpAndSettle();
    expect(set, [true]);
    expect(find.text('Frame interpolation'), findsNothing);
  });

  testWidgets('frame interpolation shows the doubled rate it plays at', (
    tester,
  ) async {
    final set = <bool>[];
    await open(
      tester,
      interpolation: (on: true, streamFps: 47.952, onSet: set.add),
    );
    expect(find.text('On · 48 fps'), findsOneWidget);
    await tester.tap(find.text('Frame interpolation'));
    await tester.pumpAndSettle();
    expect(set, [false]);
  });

  testWidgets('Compare applies when it is pressed and closes the panel', (
    tester,
  ) async {
    final applied = await open(tester);
    await tester.tap(find.text('Compare with original'));
    await tester.pumpAndSettle();
    expect(applied.single.compare, isTrue);
    expect(find.text('Compare with original'), findsNothing);
  });

  testWidgets('Compare turns off the same way', (tester) async {
    final applied = await open(
      tester,
      start: current.copyWith(compare: true),
    );
    await tester.tap(find.text('Compare with original'));
    await tester.pumpAndSettle();
    expect(applied.single.compare, isFalse);
  });

  testWidgets('Auto HDR off takes Dolby Vision with it at once', (tester) async {
    final applied = await open(tester);
    await tester.tap(find.text('Auto HDR'));
    await tester.pumpAndSettle();
    expect(applied.single.hdr, isFalse);
    expect(applied.single.dolbyVision, isFalse);
  });

  testWidgets('A live slider changes at once, with no Apply, and goes with an on/off row', (
    tester,
  ) async {
    final applied = await open(tester);
    await tester.tap(find.byTooltip('Increase').last);
    await tester.pump();
    expect(applied, isEmpty);
    expect(live.single.saturation, 110);
    expect(find.text('110'), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget, reason: 'nothing to restart for');

    await tester.tap(find.text('Deepen blacks'));
    await tester.pumpAndSettle();
    expect(applied.single.deepenBlacks, isTrue);
    expect(applied.single.saturation, 110);
  });

  testWidgets('A live change carries only the look, not what waits for Apply', (
    tester,
  ) async {
    await open(tester, start: current.copyWith(peakNits: 1000, hdrStrength: 100));
    // Tooltips run down the panel: quality, HDR strength, saturation, then peak.
    await tester.tap(find.byTooltip('Decrease').last);
    await tester.pump();
    expect(live, isEmpty, reason: 'the peak is a new stream');
    expect(find.text('Apply and restart stream'), findsOneWidget);

    await tester.tap(find.byTooltip('Decrease').at(1));
    await tester.pump();
    expect(live.single.hdrStrength, 90);
    expect(live.single.peakNits, 1000);
  });

  testWidgets('HDR strength shows only when the server names it', (tester) async {
    await open(tester);
    expect(find.text('HDR strength'), findsNothing);
  });

  testWidgets('After a live change it offers to show it now', (tester) async {
    await open(tester, start: current.copyWith(hdrStrength: 100));
    expect(find.textContaining('Show now'), findsNothing);
    await tester.tap(find.byTooltip('Decrease').at(1));
    await tester.pump();
    await tester.tap(find.textContaining('Show now'));
    await tester.pumpAndSettle();
    expect(shownNow, 1);
    expect(find.text('HDR strength'), findsNothing, reason: 'the panel closes');
  });

  testWidgets('A row that cannot change does not apply', (tester) async {
    final applied = await open(
      tester,
      start: current.copyWith(hdr: false, dolbyVision: false),
    );
    await tester.tap(find.text('Dolby Vision'));
    await tester.pumpAndSettle();
    expect(applied, isEmpty);
  });
}
