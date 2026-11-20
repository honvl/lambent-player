import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:playback_core/playback_core.dart';

import '../../../auth/repositories/session_repository.dart';
import '../../../data/local_files/local_file_library.dart';
import '../../../di/modules/playback_module.dart' show ensureLocalFilePlayback;
import '../../../l10n/app_localizations.dart';
import '../../../util/download_utils.dart';
import '../../../util/focus/indexed_focus_nodes.dart';
import '../../widgets/focus/focusable_toolbar_button.dart';
import '../../navigation/destinations.dart';
import '../../navigation/playback_launcher.dart';
import 'widgets/saved_media_menu.dart';
import 'widgets/saved_media_row.dart';

/// Plays a video file opened from outside the app, from where it was left
/// unless [fromStart].
Future<void> playLocalFile(
  BuildContext context,
  LocalFile file, {
  bool fromStart = false,
}) async {
  final getIt = GetIt.instance;
  // A signed-in server's resolver answers local files too. With none, one
  // that plays only local files stands in.
  ensureLocalFilePlayback();
  LocalFileLibrary.signedOutPlayback =
      !getIt.isRegistered<SessionRepository>() ||
      getIt<SessionRepository>().activeUserId == null;
  final library = getIt<LocalFileLibrary>();
  final manager = getIt<PlaybackManager>();
  final item = library.itemFor(file);
  final start = fromStart
      ? Duration.zero
      : Duration(microseconds: file.positionTicks ~/ 10);
  await launchPlayerWhilePreparing(
    context,
    manager: manager,
    destination: Destinations.videoPlayer,
    startPlayback: (session) async {
      await runPlaybackStart(
        session,
        () => manager.playItems([item], startPosition: start),
      );
      return true;
    },
  );
}

/// Opens the system file browser and plays the file picked, or adds them all
/// to the list when several were picked.
Future<void> pickAndPlayLocalFile(BuildContext context) async {
  final List<LocalFile> picked;
  try {
    picked = await GetIt.instance<LocalFileLibrary>().pick();
  } catch (_) {
    return;
  }
  if (picked.length == 1 && context.mounted) {
    await playLocalFile(context, picked.first);
  }
}

/// The video files opened from outside the app, newest first, under
/// Saved media's "On this device" tab.
class LocalFilesTab extends StatefulWidget {
  const LocalFilesTab({super.key, this.onNavigateUpFromFirst});

  final VoidCallback? onNavigateUpFromFirst;

  @override
  State<LocalFilesTab> createState() => _LocalFilesTabState();
}

class _LocalFilesTabState extends State<LocalFilesTab> {
  final _library = GetIt.instance<LocalFileLibrary>();
  final _rowNodes = IndexedFocusNodes('LocalFileRow');

  @override
  void initState() {
    super.initState();
    _library.addListener(_changed);
    unawaited(_library.load());
  }

  @override
  void dispose() {
    _library.removeListener(_changed);
    _rowNodes.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final files = _library.files;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => pickAndPlayLocalFile(context),
              icon: const Icon(Icons.folder_open),
              label: Text(l10n.openVideoFile),
            ),
          ),
        ),
        Expanded(
          child: files.isEmpty
              ? _empty(l10n)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                  itemCount: files.length,
                  itemBuilder: (context, index) =>
                      _row(l10n, files[index], index, files.length),
                ),
        ),
      ],
    );
  }

  Widget _row(AppLocalizations l10n, LocalFile file, int index, int total) {
    final progress = file.progress;
    return SavedMediaRow(
      key: ValueKey(file.id),
      rowFocusNode: _rowNodes[index],
      title: file.title,
      subtitle: progress > 0
          ? l10n.localFileResumeAt(_clock(file.positionTicks))
          : file.name,
      sizeLabel: formatBytes(file.size),
      fallbackIcon: Icons.insert_drive_file_outlined,
      onActivate: () => playLocalFile(context, file),
      onPlay: () => playLocalFile(context, file),
      onMenu: () => _menu(l10n, file),
      onNavigateUp: () => index == 0
          ? widget.onNavigateUpFromFirst?.call()
          : _rowNodes[index - 1].requestFocus(),
      onNavigateDown: () =>
          index + 1 < total ? _rowNodes[index + 1].requestFocus() : null,
    );
  }

  Future<void> _menu(AppLocalizations l10n, LocalFile file) {
    return showSavedMediaMenu(
      context,
      title: file.title,
      actions: [
        SavedMediaAction(
          icon: Icons.play_arrow,
          label: file.progress > 0 ? l10n.resume : l10n.play,
          onSelect: () => playLocalFile(context, file),
        ),
        if (file.progress > 0)
          SavedMediaAction(
            icon: Icons.replay,
            label: l10n.startOver,
            onSelect: () => playLocalFile(context, file, fromStart: true),
          ),
        SavedMediaAction(
          icon: Icons.playlist_remove,
          label: l10n.removeFromList,
          isDestructive: true,
          onSelect: () => _library.remove(file.id),
        ),
      ],
    );
  }

  Widget _empty(AppLocalizations l10n) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        l10n.localFilesEmpty,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppColorScheme.onSurface.withValues(alpha: 0.6),
          fontSize: 14,
        ),
      ),
    ),
  );

  static String _clock(int ticks) {
    final d = Duration(microseconds: ticks ~/ 10);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// "On this device" on its own, for the server screen: reached with nobody
/// signed in, so it leans on nothing a server provides.
class LocalFilesScreen extends StatelessWidget {
  const LocalFilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Row(
                children: [
                  FocusableToolbarButton(
                    icon: Icons.arrow_back,
                    tooltip: l10n.back,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.onThisDevice,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColorScheme.onSurface,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Expanded(child: LocalFilesTab()),
          ],
        ),
      ),
    );
  }
}
