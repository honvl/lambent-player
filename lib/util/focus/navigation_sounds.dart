import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'dpad_keys.dart';

/// The ticks an Android TV app's own views make as the remote moves focus and
/// selects, which Flutter's single view never asks for. Android plays them
/// only while the device's System sounds setting is on, as it does for Plex
/// and the launcher.
class NavigationSounds {
  NavigationSounds._(this._play);

  static NavigationSounds? _instance;

  /// Starts the ticks for the whole app. Android TV only; call once.
  static void install() {
    if (_instance != null) return;
    const channel = MethodChannel('org.moonfin.androidtv/platform');
    _instance = NavigationSounds._(
      (sound) => channel.invokeMethod<void>('playNavigationSound', sound).catchError((_) {}),
    )..start();
  }

  /// A tick a test can hear: [play] gets `up`, `down`, `left`, `right` or `select`.
  @visibleForTesting
  factory NavigationSounds.forTest(void Function(String sound) play) => NavigationSounds._(play);

  final void Function(String sound) _play;

  static const _keyWindow = Duration(milliseconds: 250);

  /// The direction of the arrow key being handled, until focus moves for it.
  String? _pending;
  DateTime? _pendingAt;
  FocusNode? _focused;

  void start() {
    _focused = FocusManager.instance.primaryFocus;
    HardwareKeyboard.instance.addHandler(_onKey);
    FocusManager.instance.addListener(_onFocusChange);
  }

  void stop() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    FocusManager.instance.removeListener(_onFocusChange);
  }

  bool _onKey(KeyEvent event) {
    if (!event.isActionable) return false;
    final key = event.logicalKey;
    if (key.isUpKey) {
      _pending = 'up';
    } else if (key.isDownKey) {
      _pending = 'down';
    } else if (key.isLeftKey) {
      _pending = 'left';
    } else if (key.isRightKey) {
      _pending = 'right';
    } else {
      // Any other key ends the last arrow's claim on the next move.
      _pending = null;
      if (event is KeyDownEvent && _selects(key) && FocusManager.instance.primaryFocus != null) _play('select');
    }
    if (_pending != null) _pendingAt = DateTime.now();
    return false;
  }

  /// Space types into a text field, so only the remote's and a keyboard's
  /// confirm keys tick.
  static bool _selects(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;

  void _onFocusChange() {
    final focused = FocusManager.instance.primaryFocus;
    if (identical(focused, _focused)) return;
    _focused = focused;
    final direction = _pending;
    final at = _pendingAt;
    _pending = null;
    // Focus moves while the key is handled, or a frame later where a row
    // scrolls first. A key that moved nothing (the end of a row, a seek in
    // the player) stays silent, as on Android, and a move long after it is
    // the app's own.
    if (direction == null || focused == null || at == null) return;
    if (DateTime.now().difference(at) < _keyWindow) _play(direction);
  }
}
