import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/widgets.dart';

/// What kind of touch screen the app is drawn on right now: a phone, a tablet,
/// or a foldable, and where a foldable's hinge or fold runs.
///
/// Read from [MediaQuery] on every build, never cached, so a foldable that is
/// opened or closed (or an iPad window resized in Split View or Stage Manager)
/// switches layout on the next frame. Sizes follow Material's window size
/// classes: under 600 dp across is compact (a phone, or a folded foldable),
/// 600 to 839 dp wide is medium, 840 dp and up is expanded.
@immutable
class FormFactor {
  const FormFactor._(this.size, this.features);

  factory FormFactor.of(BuildContext context) => FormFactor.from(
    MediaQuery.sizeOf(context),
    MediaQuery.displayFeaturesOf(context),
  );

  /// For code that runs without a context, such as a player's first frame.
  factory FormFactor.ofView(FlutterView view) {
    final ratio = view.devicePixelRatio;
    return FormFactor.from(view.physicalSize / ratio, [
      for (final f in view.displayFeatures)
        DisplayFeature(
          bounds: Rect.fromLTRB(
            f.bounds.left / ratio,
            f.bounds.top / ratio,
            f.bounds.right / ratio,
            f.bounds.bottom / ratio,
          ),
          type: f.type,
          state: f.state,
        ),
    ]);
  }

  factory FormFactor.from(Size size, List<DisplayFeature> features) =>
      FormFactor._(size, [
        for (final f in features)
          if (f.type == DisplayFeatureType.fold ||
              f.type == DisplayFeatureType.hinge)
            f,
      ]);

  static const double mediumWidth = 600;
  static const double expandedWidth = 840;

  final Size size;

  /// The folds and hinges crossing the window, in logical pixels. Cutouts are
  /// left out: they never split content.
  final List<DisplayFeature> features;

  /// A phone, or a foldable folded shut: under 600 dp on the short side.
  bool get isPhone => size.shortestSide < mediumWidth;

  /// An iPad, an Android tablet, or an unfolded foldable.
  bool get isTablet => !isPhone;

  /// A fold or hinge crosses the window, so this is a foldable that is open.
  bool get isUnfoldedFoldable => features.isNotEmpty;

  /// Wide enough for content beside content (840 dp), or split by a vertical
  /// fold that puts the two halves side by side.
  bool get isExpanded =>
      size.width >= expandedWidth || verticalSeparator != null;

  /// Whether a list and its details belong side by side.
  bool get twoPane => isExpanded;

  /// A fold or hinge running top to bottom, so the screen opens like a book.
  DisplayFeature? get verticalSeparator => _separator(vertical: true);

  /// A fold or hinge running side to side: tabletop posture when half open.
  DisplayFeature? get horizontalSeparator => _separator(vertical: false);

  /// Half open with the fold across the middle, laptop style: the top half for
  /// the picture and the bottom half for the controls.
  bool get isTabletop =>
      horizontalSeparator?.state == DisplayFeatureState.postureHalfOpened;

  DisplayFeature? _separator({required bool vertical}) {
    for (final f in features) {
      final b = f.bounds;
      final runsVertically =
          b.height >= size.height - 1 && b.width < size.width;
      final runsHorizontally =
          b.width >= size.width - 1 && b.height < size.height;
      // A flat fold with no width splits nothing; a hinge always does, and so
      // does a fold that is bent.
      final splits =
          f.type == DisplayFeatureType.hinge ||
          (b.width > 0 && b.height > 0) ||
          f.state == DisplayFeatureState.postureHalfOpened;
      if (!splits) continue;
      if (vertical ? runsVertically : runsHorizontally) return f;
    }
    return null;
  }

  /// Where a two-pane layout puts its divider: the vertical fold when there
  /// is one, otherwise [fallback] of the width.
  double paneSplit({double fallback = 0.42}) {
    final fold = verticalSeparator;
    if (fold != null) return fold.bounds.left;
    return size.width * fallback;
  }

  /// The gap a two-pane layout leaves for a physical hinge (zero for a fold).
  double get paneGap => verticalSeparator?.bounds.width ?? 0;
}
