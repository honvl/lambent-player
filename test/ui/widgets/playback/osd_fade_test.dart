import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/widgets/playback/osd_fade.dart';

void main() {
  final focus = FocusNode();
  tearDownAll(focus.dispose);

  Widget controls() => Focus(
    focusNode: focus,
    autofocus: true,
    child: const Text('bar', textDirection: TextDirection.ltr),
  );

  Future<void> pump(WidgetTester tester, {required bool shown}) =>
      tester.pumpWidget(OsdFade(child: shown ? controls() : null));

  double opacity(WidgetTester tester) => tester
      .widget<FadeTransition>(find.byType(FadeTransition))
      .opacity
      .value;

  testWidgets('fades in from nothing', (tester) async {
    await pump(tester, shown: true);
    expect(opacity(tester), 0);
    await tester.pump(OsdFade.fadeIn ~/ 2);
    expect(opacity(tester), inExclusiveRange(0, 1));
    await tester.pump(OsdFade.fadeIn);
    expect(opacity(tester), 1);
  });

  testWidgets('fades out still drawn, without focus, then leaves', (
    tester,
  ) async {
    await pump(tester, shown: true);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);

    await pump(tester, shown: false);
    await tester.pump(OsdFade.fadeOut ~/ 2);
    expect(find.text('bar'), findsOneWidget);
    expect(opacity(tester), inExclusiveRange(0, 1));
    expect(focus.hasFocus, isFalse);

    await tester.pump(OsdFade.fadeOut);
    await tester.pump();
    expect(find.text('bar'), findsNothing);
  });

  testWidgets('shown again mid-fade comes back from where it was', (
    tester,
  ) async {
    await pump(tester, shown: true);
    await tester.pumpAndSettle();
    await pump(tester, shown: false);
    await tester.pump(OsdFade.fadeOut ~/ 2);
    final halfway = opacity(tester);

    await pump(tester, shown: true);
    expect(opacity(tester), closeTo(halfway, 0.01));
    await tester.pumpAndSettle();
    expect(opacity(tester), 1);
    expect(find.text('bar'), findsOneWidget);
  });
}
