import 'dart:async';

import 'package:flutter/foundation.dart';

/// Whether the player should be plain black while a start is under way.
///
/// A television that matches frame rates goes dark for a second or two as the
/// player opens, while HDMI renegotiates. It comes back to the loading
/// animation, and then the picture's arrival can blank it again: a Shield
/// shows the first Dolby Vision frames through its menu pipeline and, some
/// 0.6 s on, drops five frames switching to its video one. That reads as two
/// blinks with flashes of the player between them. Holding black from the
/// moment the player opens until the picture has settled joins them into one.
///
/// The wait for the stream has no ceiling, so the hold does: past [longest]
/// the loading animation shows as it always did.
class StartCover extends ValueNotifier<bool> {
  StartCover({
    this.undecided = const Duration(seconds: 2),
    this.longest = const Duration(seconds: 6),
    this.afterFirstFrame = const Duration(milliseconds: 250),
    this.afterDolbyVisionFrame = const Duration(milliseconds: 1000),
  }) : super(false);

  /// How long [arm] holds while nobody has said whether the display switches.
  final Duration undecided;

  final Duration longest;

  /// Kept past the first frame, over the frames the display drops for it.
  final Duration afterFirstFrame;

  /// The same for Dolby Vision, whose switch comes later and blanks longer.
  final Duration afterDolbyVisionFrame;

  Timer? _timer;
  DateTime? _decidedAt;

  /// The player has opened and may be about to switch the display: black
  /// until [begin] or [end] says which. A screen that opens after that was
  /// settled changes nothing.
  void arm() {
    if (value) return;
    final decided = _decidedAt;
    if (decided != null && DateTime.now().difference(decided) < undecided) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(undecided, end);
    value = true;
  }

  /// The display has been asked to change mode for the start that follows.
  void begin() {
    _decidedAt = DateTime.now();
    _timer?.cancel();
    _timer = Timer(longest, end);
    value = true;
  }

  void firstFrame({bool dolbyVision = false}) {
    if (!value) return;
    _timer?.cancel();
    _timer = Timer(dolbyVision ? afterDolbyVisionFrame : afterFirstFrame, end);
  }

  /// No display switch is coming, or the start is over, failed or abandoned.
  void end() {
    _decidedAt = DateTime.now();
    _timer?.cancel();
    _timer = null;
    value = false;
  }
}
