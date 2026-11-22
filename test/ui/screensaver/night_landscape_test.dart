import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screensaver/screensaver_night_landscape.dart';

/// Paints the night landscape at a few moments. Set LAMBENT_PREVIEW_DIR to
/// also write each frame there as a PNG.
void main() {
  test('a shooting star window comes once a cycle and lasts about a second', () {
    var frames = 0;
    var windows = 0;
    var inside = false;
    for (var t = 3300.0; t < 3300.0 + 55 * 4; t += 1 / 60) {
      final active = NightLandscapePainter.shootingStarActive(t);
      if (active) frames++;
      if (active && !inside) windows++;
      inside = active;
    }
    expect(windows, inInclusiveRange(3, 5));
    expect(frames / windows / 60, closeTo(1.3, 0.05));
  });

  for (final seconds in [600.0, 3600.0, 5400.0]) {
    testWidgets('paints the night landscape at ${seconds}s', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: Colors.black,
            child: CustomPaint(
              size: Size.infinite,
              painter: NightLandscapePainter(ValueNotifier(seconds)),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      final dir = Platform.environment['LAMBENT_PREVIEW_DIR'];
      if (dir == null) return;
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$dir/night_${seconds.round()}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
    });
  }
}
