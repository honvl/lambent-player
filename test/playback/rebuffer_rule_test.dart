import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

void main() {
  final now = DateTime(2026, 11, 4, 21);

  test('one rebuffer is not enough', () {
    expect(RebufferRule.shouldReopen(1, null, now), isFalse);
  });

  test('a second one reopens', () {
    expect(RebufferRule.shouldReopen(2, null, now), isTrue);
  });

  test('a connection that stays bad is not reopened over and over', () {
    final recent = now.subtract(const Duration(minutes: 1));
    expect(RebufferRule.shouldReopen(5, recent, now), isFalse);
    final earlier = now.subtract(RebufferRule.atMostEvery);
    expect(RebufferRule.shouldReopen(2, earlier, now), isTrue);
  });
}
