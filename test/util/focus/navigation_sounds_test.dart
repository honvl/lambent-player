import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/util/focus/navigation_sounds.dart';

void main() {
  testWidgets('a move ticks its direction, a key that moves nothing is silent, select clicks', (tester) async {
    final heard = <String>[];
    final sounds = NavigationSounds.forTest(heard.add);
    final first = FocusNode(), second = FocusNode();
    addTearDown(() {
      sounds.stop();
      first.dispose();
      second.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      home: Row(children: [
        Focus(focusNode: first, child: const SizedBox(width: 50, height: 50)),
        Focus(focusNode: second, child: const SizedBox(width: 50, height: 50)),
      ]),
    ));
    first.requestFocus();
    await tester.pump();
    sounds.start();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(heard, ['right']);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(heard, ['right'], reason: 'the end of the row');

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(heard, ['right', 'select']);

    first.requestFocus();
    await tester.pump();
    expect(heard, ['right', 'select'], reason: 'the app moved focus, not the remote');
  });
}
