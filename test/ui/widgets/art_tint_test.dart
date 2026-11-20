import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/widgets/art_tint.dart';

Uint8List _pixels(List<Color> colors) => Uint8List.fromList([
  for (final c in colors) ...[
    (c.r * 255).round(),
    (c.g * 255).round(),
    (c.b * 255).round(),
    255,
  ],
]);

void main() {
  test('a red poster on grey makes a dark red page', () {
    final tint = ArtTint.tintFromPixels(
      _pixels([
        ...List.filled(20, const Color(0xFF808080)),
        ...List.filled(4, const Color(0xFFE02010)),
      ]),
    )!;
    final hsl = HSLColor.fromColor(tint);
    expect(hsl.hue, lessThan(20));
    expect(hsl.lightness, closeTo(0.2, 0.01));
    expect(hsl.saturation, greaterThan(0.4));
  });

  test('grey art makes a near-neutral page', () {
    final tint = ArtTint.tintFromPixels(
      _pixels(List.filled(24, const Color(0xFF707070))),
    )!;
    expect(HSLColor.fromColor(tint).saturation, lessThan(0.05));
  });

  test('a fully transparent image has no tint', () {
    expect(ArtTint.tintFromPixels(Uint8List(4 * 24)), isNull);
  });
}
