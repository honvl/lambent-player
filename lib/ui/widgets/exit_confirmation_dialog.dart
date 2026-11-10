import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../l10n/app_localizations.dart';
import '../../util/app_exit.dart';
import '../../util/focus/key_event_utils.dart';
import 'navigation_layout.dart';
import 'overlay_sheet.dart';

bool _exitDialogVisible = false;

Future<void> showExitConfirmationDialog(BuildContext context) async {
  if (_exitDialogVisible) return;
  _exitDialogVisible = true;
  final l10n = AppLocalizations.of(context);
  final cancelFocus = FocusNode(debugLabel: 'ExitDialogCancel');
  try {
    final result = await OverlaySheetController.show<bool>(
      context,
      initialFocusNode: cancelFocus,
      builder: (sheetContext) => _ExitConfirmationContent(
        title: l10n.exitApp,
        message: l10n.exitAppConfirmation,
        cancelLabel: l10n.cancel,
        exitLabel: l10n.exit,
        cancelFocus: cancelFocus,
        onCancel: () => OverlaySheetController.closeAdaptive<bool>(
          sheetContext,
          result: false,
        ),
        onExit: () => OverlaySheetController.closeAdaptive<bool>(
          sheetContext,
          result: true,
        ),
      ),
    );
    if (result == true) {
      await AppExit.closeApp();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final focusAvatar = NavigationLayout.focusNavbarAvatarNotifier.value;
        if (focusAvatar != null) {
          focusAvatar();
          return;
        }
        NavigationLayout.focusNavbarNotifier.value?.call();
      });
    }
  } finally {
    _exitDialogVisible = false;
    cancelFocus.dispose();
  }
}

class _ExitConfirmationContent extends StatefulWidget {
  final String title;
  final String message;
  final String cancelLabel;
  final String exitLabel;
  final FocusNode cancelFocus;
  final VoidCallback onCancel;
  final VoidCallback onExit;

  const _ExitConfirmationContent({
    required this.title,
    required this.message,
    required this.cancelLabel,
    required this.exitLabel,
    required this.cancelFocus,
    required this.onCancel,
    required this.onExit,
  });

  @override
  State<_ExitConfirmationContent> createState() =>
      _ExitConfirmationContentState();
}

class _ExitConfirmationContentState extends State<_ExitConfirmationContent> {
  final _exitFocus = FocusNode(debugLabel: 'ExitDialogExit');

  @override
  void dispose() {
    _exitFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The sheet sits in the overlay with no Material above it, so without one
    // the text fell back to the platform font instead of the theme's.
    final theme = Theme.of(context);
    final glass = AppColorScheme.isGlass;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.spaceXl,
        AppSpacing.spaceLg,
        AppSpacing.spaceXl,
        AppSpacing.spaceLg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: AppTypography.fontSize2xl,
              fontWeight: FontWeight.w600,
              color: AppColorScheme.onSurface,
            ),
          ),
          const SizedBox(height: AppSpacing.spaceXs),
          Text(
            widget.message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: AppTypography.fontSizeMd,
              color: AppColorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: AppSpacing.spaceLg),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ExitDialogButton(
                label: widget.cancelLabel,
                focusNode: widget.cancelFocus,
                autofocus: true,
                onPressed: widget.onCancel,
              ),
              const SizedBox(width: AppSpacing.spaceSm),
              _ExitDialogButton(
                label: widget.exitLabel,
                focusNode: _exitFocus,
                onPressed: widget.onExit,
              ),
            ],
          ),
        ],
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 360, maxWidth: 440),
        // The same glass as the player's popovers and its control bar.
        child: GlassSurface(
          cornerRadius: glass ? 32 : 16,
          reinforced: true,
          fallbackColor: AppColorScheme.surface,
          // TV boxes draw glass without blur, so the screen's own text would
          // show through. The player bar's dark tint, a little stronger since
          // this sits over the app rather than video, keeps it readable.
          child: glass
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xB3101218),
                    borderRadius: AppRadius.circular(32),
                  ),
                  child: content,
                )
              : content,
        ),
      ),
    );
  }
}

class _ExitDialogButton extends StatefulWidget {
  final String label;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final bool autofocus;

  const _ExitDialogButton({
    required this.label,
    required this.focusNode,
    required this.onPressed,
    this.autofocus = false,
  });

  @override
  State<_ExitDialogButton> createState() => _ExitDialogButtonState();
}

class _ExitDialogButtonState extends State<_ExitDialogButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final glass = AppColorScheme.isGlass;
    // Pills in the player bar's button style: a faint glass fill at rest, a
    // brighter fill with the white focus ring and glow when focused.
    final Color fill;
    final Color textColor;
    if (glass) {
      fill = _focused ? const Color(0x52FFFFFF) : const Color(0x1AFFFFFF);
      textColor = Colors.white;
    } else {
      fill = _focused
          ? AppColorScheme.buttonFocused
          : AppColorScheme.buttonNormal;
      textColor = _focused
          ? AppColorScheme.onButtonFocused
          : AppColorScheme.onButtonNormal;
    }
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) => handleOneShotSelect(event, widget.onPressed),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 150),
          scale: _focused && glass ? 1.06 : 1.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 46,
            constraints: const BoxConstraints(minWidth: 120),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.spaceLg),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: AppRadius.circular(999),
              border: glass
                  ? Border.fromBorderSide(
                      _focused
                          ? const BorderSide(color: Colors.white, width: 3)
                          : const BorderSide(
                              color: Color(0x24FFFFFF),
                              width: 1.5,
                            ),
                    )
                  : null,
              boxShadow: _focused && glass
                  ? const [BoxShadow(color: Color(0x40FFFFFF), blurRadius: 24)]
                  : null,
            ),
            child: Text(
              widget.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: AppTypography.fontSizeMd,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
