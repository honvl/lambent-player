import 'package:flutter/material.dart';

import '../../../../../data/models/aggregated_item.dart';
import '../../../../../data/viewmodels/item_detail_view_model.dart';
import '../../../../../l10n/app_localizations.dart';
import '../../../../../preference/preference_constants.dart';
import '../../../../../preference/user_preferences.dart';
import '../../../../widgets/focus/locked_focus_row.dart';
import '../../../../widgets/navigation_layout.dart';
import '../shared/nouveau_spacing.dart';
import 'nouveau_discovery_card.dart';
import 'nouveau_discovery_rail.dart';

/// Plex's rows under Related: "More from" the studio, then "More with" each of the first two actors
/// ([ItemDetailViewModel.moreRows]).
class NouveauMoreRowsSection extends StatefulWidget {
  final ItemDetailViewModel viewModel;
  final UserPreferences prefs;
  final bool Function()? onNavigateUp;
  final bool Function()? onNavigateDown;
  final ValueChanged<GlobalKey>? onRevealRequested;

  const NouveauMoreRowsSection({
    super.key,
    required this.viewModel,
    required this.prefs,
    this.onNavigateUp,
    this.onNavigateDown,
    this.onRevealRequested,
  });

  static bool shouldInclude(ItemDetailViewModel viewModel) => viewModel.moreRows.isNotEmpty;

  @override
  State<NouveauMoreRowsSection> createState() => NouveauMoreRowsSectionState();
}

class _RowState {
  _RowState(TickerProvider vsync)
      : opacity = AnimationController(vsync: vsync, duration: const Duration(milliseconds: 220), value: 1);

  final AnimationController opacity;
  final rowKey = GlobalKey<LockedFocusRowState<AggregatedItem>>();
  final revealKey = GlobalKey();
  final controller = ScrollController();

  void dispose() {
    opacity.dispose();
    controller.dispose();
  }
}

class NouveauMoreRowsSectionState extends State<NouveauMoreRowsSection> with TickerProviderStateMixin {
  static int _session = 0;

  late final int _hub = _session++;
  final List<_RowState> _states = [];

  List<MoreRow> get _rows => widget.viewModel.moreRows;

  bool get canFocusTop => _rows.isNotEmpty && _states.isNotEmpty && _states.first.rowKey.currentState != null;

  GlobalKey? get topRevealKey => _states.isEmpty ? null : _states.first.revealKey;

  GlobalKey? get bottomRevealKey => _states.isEmpty ? null : _states[_rows.length - 1].revealKey;

  bool focusTop() => _focusRow(0, reveal: false);

  bool focusBottom() => _focusRow(_rows.length - 1, reveal: false);

  @override
  void dispose() {
    for (final state in _states) {
      state.dispose();
    }
    super.dispose();
  }

  bool _focusRow(int index, {bool reveal = true}) {
    if (index < 0 || index >= _rows.length || index >= _states.length) return false;
    final row = _states[index].rowKey.currentState;
    if (row == null) return false;
    row.requestFocusFromMemory();
    if (reveal) widget.onRevealRequested?.call(_states[index].revealKey);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows.isEmpty) return const SizedBox.shrink();
    while (_states.length < rows.length) {
      _states.add(_RowState(this));
    }
    final l10n = AppLocalizations.of(context);
    final navbarIsLeft = widget.prefs.get(UserPreferences.navbarPosition) == NavbarPosition.left;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: NouveauSpacing.sectionGap),
          KeyedSubtree(
            key: _states[i].revealKey,
            child: NouveauDiscoveryRail(
              title: rows[i].studio != null ? l10n.moreFromStudio(rows[i].studio!) : l10n.moreWithPerson(rows[i].person ?? ''),
              items: rows[i].items,
              showSkeleton: false,
              opacity: _states[i].opacity,
              rowKey: _states[i].rowKey,
              hubKey: 'nouveau-more-$_hub-$i',
              controller: _states[i].controller,
              onNavigateUp: () => _focusRow(i - 1) || (widget.onNavigateUp?.call() ?? false),
              onNavigateDown: () => _focusRow(i + 1) || (widget.onNavigateDown?.call() ?? false),
              onTap: (item) => NouveauDiscoveryCard.openItem(context, item),
              onLeftEdge: navbarIsLeft ? () => NavigationLayout.focusNavbarNotifier.value?.call() : null,
              itemBuilder: (context, item, width, isFocused) => NouveauDiscoveryCard(
                item: item,
                imageApi: widget.viewModel.imageApi,
                prefs: widget.prefs,
                width: width,
                isFocused: isFocused,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
