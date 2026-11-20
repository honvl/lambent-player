import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../preference/preference_constants.dart';
import '../../preference/user_preferences.dart';
import '../../util/clock_format.dart';
import '../../util/tv_ui_scale.dart';
import 'navigation_layout.dart';

/// The time in a small dark pill at the top right of a TV page, where Plex's
/// TV app keeps it. Follows the clock setting (shown unless it is Never) and
/// the 24-hour choice, and steps aside while a trailer hides the chrome.
class TvClockPill extends StatefulWidget {
  const TvClockPill({super.key});

  @override
  State<TvClockPill> createState() => _TvClockPillState();
}

class _TvClockPillState extends State<TvClockPill> {
  final _prefs = GetIt.instance<UserPreferences>();
  Timer? _timer;
  String _time = '';

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    final time = formatClockTime(
      DateTime.now(),
      use24Hour: _prefs.get(UserPreferences.use24HourClock),
    );
    if (time != _time && mounted) setState(() => _time = time);
  }

  @override
  Widget build(BuildContext context) {
    if (_prefs.get(UserPreferences.clockBehavior) == ClockBehavior.never) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: NavigationLayout.trailerChromeListenable,
        builder: (context, child) => AnimatedOpacity(
          opacity: NavigationLayout.trailerHidesChrome ? 0 : 1,
          duration: const Duration(milliseconds: 200),
          child: child,
        ),
        child: Padding(
          padding: EdgeInsets.only(top: tvPx(40), right: tvPx(96)),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: tvPx(22),
              vertical: tvPx(10),
            ),
            decoration: BoxDecoration(
              color: const Color(0x8C000000),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              _time,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: tvPx(24),
                fontWeight: FontWeight.w500,
                height: 1.1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
