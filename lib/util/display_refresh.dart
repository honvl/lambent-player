import 'dart:ui' show PlatformDispatcher;

import 'display_refresh_io.dart'
    if (dart.library.js_interop) 'display_refresh_web.dart'
    as impl;

/// This screen's refresh rate, in Hz, sent as the `Lambent` object's
/// `DisplayHz` so the PC makes an interpolated stream at a rate the screen
/// shows evenly: 24 fps as 60 on a 60 or 120 Hz screen, as 48 on a 144 Hz one.
abstract class DisplayRefresh {
  /// The rate now, or null before a browser has measured it.
  static double? get hz {
    final measured = impl.measuredHz;
    if (measured != null) return measured;
    if (impl.measures) return null;
    final rate = PlatformDispatcher.instance.displays.firstOrNull?.refreshRate;
    return rate != null && rate > 0 ? rate : null;
  }

  /// Starts a browser's measurement (Flutter's web engine says 60 whatever
  /// the screen); nothing elsewhere.
  static void measure() => impl.measure();

  /// A measured rate as the screen's own when it is near one (frame times
  /// jitter); otherwise as measured.
  static double nearest(double measured) {
    const rates = [
      24.0, 30.0, 48.0, 50.0, 59.94, 60.0, 72.0, 75.0, 90.0, 100.0, 120.0, //
      144.0, 165.0, 240.0,
    ];
    for (final rate in rates) {
      if ((measured - rate).abs() <= rate * 0.015) {
        // 59.94 and 60 are closer than frame timing tells apart: 60.
        return rate == 59.94 ? 60.0 : rate;
      }
    }
    return measured;
  }
}
