import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../util/platform_detection.dart';
import '../../../util/tv_ui_scale.dart';

/// The item's name drawn in place of its logo, for items that have no logo
/// image or whose logo fails to load. Each layout passes its own [shadows] so
/// the text sits against its backdrop the same way the rest of that layout does.
class MediaBarTitle extends StatelessWidget {
  const MediaBarTitle({
    super.key,
    required this.title,
    required this.shadows,
    this.hero = false,
  });

  final String title;
  final List<Shadow> shadows;

  /// The Lambent glass hero title: big, semibold and tightly tracked (104px
  /// weight 600, -0.025em on a 1920 canvas), stepping down for long names so
  /// they stay inside two lines.
  final bool hero;

  @override
  Widget build(BuildContext context) {
    if (hero) {
      final size = tvPx(
        title.length <= 14
            ? 104
            : title.length <= 28
            ? 80
            : 60,
      );
      return Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppColorScheme.onSurface,
          fontSize: size,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.025 * size,
          height: 1.0,
          shadows: shadows,
        ),
      );
    }
    final theme = Theme.of(context);
    final style = PlatformDetection.useMobileUi
        ? theme.textTheme.titleLarge
        : theme.textTheme.headlineMedium;
    return Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: style?.copyWith(
        color: AppColorScheme.onSurface,
        fontWeight: FontWeight.w800,
        height: 1.05,
        shadows: shadows,
      ),
    );
  }
}
