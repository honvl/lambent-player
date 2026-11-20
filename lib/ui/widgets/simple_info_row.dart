import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../data/models/aggregated_item.dart';
import '../../util/tv_ui_scale.dart';

final _textShadows = [
  Shadow(blurRadius: 4, color: AppColors.black.withValues(alpha: 0.54)),
];

/// The one line under the classic home info area's title.
class SimpleInfoRow extends StatelessWidget {
  final AggregatedItem item;
  final String? metadataSummary;

  const SimpleInfoRow({super.key, required this.item, this.metadataSummary});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final locale = Localizations.maybeLocaleOf(context)?.toLanguageTag();
    // Plex spaces its facts apart; a library's own summary keeps its dots.
    var spaced = false;

    final summary = metadataSummary;
    if (summary != null && summary.isNotEmpty) {
      final parts = summary
          .split(' • ')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty);
      for (final part in parts) {
        children.add(_text(part));
      }
    } else {
      // Plex's order: the season and episode lead an episode's line, since
      // the title band shows the series; then the year (an episode's air
      // date), the runtime, two genres, and the age rating last.
      if (item.type == 'Episode') {
        final lead = episodeLead(item);
        if (lead.isNotEmpty) children.add(_text(lead, lead: true));
      }

      final aired = item.type == 'Episode' ? item.premiereDate : null;
      if (aired != null) {
        // An air date is a day, sent as its UTC midnight: read it as that day.
        children.add(_text(DateFormat.yMMMd(locale).format(aired.toUtc())));
      } else if (item.productionYear != null) {
        children.add(_text(item.productionYear.toString()));
      }

      final runtime = item.runtime;
      if (runtime != null && runtime.inMinutes > 0 && item.type != 'Series') {
        final hours = runtime.inHours;
        final minutes = runtime.inMinutes.remainder(60);
        children.add(_text(hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m'));
      }

      final genres = item.genres;
      if (genres.isNotEmpty && item.type != 'Episode') {
        children.add(_text(genres.take(2).join(', ')));
      }

      if (item.officialRating case final rating? when rating.isNotEmpty) {
        children.add(_pill(rating));
      }

      final resolution = item.videoResolution;
      if (resolution != null) {
        children.add(_pill(resolution));
      }
      spaced = true;
    }

    if (children.isEmpty) return const SizedBox.shrink();

    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) separated.add(spaced ? SizedBox(width: tvPx(22)) : _dot());
      separated.add(children[i]);
    }

    // One line, cut off at the edge rather than wrapped.
    return UnconstrainedBox(
      alignment: AlignmentDirectional.centerStart,
      constrainedAxis: Axis.vertical,
      clipBehavior: Clip.hardEdge,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: separated,
      ),
    );
  }

  /// "S2 • E5  Episode Name", or whichever half the item has, as Plex
  /// writes it.
  static String episodeLead(AggregatedItem item) {
    final s = item.parentIndexNumber;
    final e = item.indexNumber;
    final number = (s != null && e != null) ? 'S$s \u2022 E$e' : null;
    final name = item.name.trim();
    return [?number, if (name.isNotEmpty) name].join('  ');
  }

  Widget _text(String value, {bool lead = false}) {
    return Text(
      value,
      maxLines: 1,
      softWrap: false,
      style: TextStyle(
        fontSize: tvPx(24),
        height: 1.2,
        fontWeight: lead ? FontWeight.w600 : FontWeight.w500,
        color: lead
            ? AppColorScheme.onSurface
            : AppColorScheme.onSurface.withValues(alpha: 0.8),
        shadows: _textShadows,
      ),
    );
  }

  Widget _dot() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tvPx(12)),
      child: Text(
        '•',
        style: TextStyle(
          fontSize: tvPx(24),
          height: 1.2,
          color: AppColorScheme.onSurface.withValues(alpha: 0.5),
          shadows: _textShadows,
        ),
      ),
    );
  }

  Widget _pill(String label) {
    final borders = ThemeRegistry.active.borders;
    return Container(
      height: tvPx(28),
      padding: EdgeInsets.symmetric(horizontal: tvPx(10)),
      decoration: BoxDecoration(
        color: borders.chipBackground,
        border: Border.fromBorderSide(borders.chipBorder),
        borderRadius: borders.chipRadius,
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          style: TextStyle(
            fontSize: tvPx(20),
            height: 1.2,
            fontWeight: FontWeight.w500,
            color: AppColorScheme.onSurface.withValues(alpha: 0.85),
            shadows: _textShadows,
          ),
        ),
      ),
    );
  }
}
