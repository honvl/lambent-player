import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'display_refresh.dart';

/// A browser times its animation frames: Flutter's web engine reports 60.
const measures = true;

double? measuredHz;

bool _measuring = false;

/// Times 60 animation frames and keeps the median interval's rate. A hidden
/// tab gets few or none, so it is tried again later.
void measure() {
  if (_measuring || measuredHz != null) return;
  _measuring = true;
  final stamps = <double>[];
  void frame(double now) {
    stamps.add(now);
    if (stamps.length < 61) {
      web.window.requestAnimationFrame(frame.toJS);
      return;
    }
    _measuring = false;
    final gaps = [
      for (var i = 1; i < stamps.length; i++) stamps[i] - stamps[i - 1],
    ]..sort();
    final median = gaps[gaps.length ~/ 2];
    // Slower than 20 Hz is a throttled tab, not the screen.
    if (median > 0 && median < 50) {
      measuredHz = DisplayRefresh.nearest(1000 / median);
    }
  }

  web.window.requestAnimationFrame(frame.toJS);
}
