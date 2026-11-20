import 'package:playback_core/playback_core.dart';

import '../data/local_files/local_file_library.dart';
import '../data/repositories/offline_repository.dart';

/// Decorates the server play-session service so local-file playback keeps the
/// downloads DB position current (the source of truth for offline resume) and
/// only talks to the server when it's reachable.
///
/// The manager fires these callbacks unawaited, so server failures while
/// offline must be swallowed here. The sync service flushes the locally
/// recorded progress on reconnect.
class LocalAwarePlayerService implements PlayerService {
  final PlayerService _inner;
  final OfflineRepository _offlineRepo;
  final bool Function() _canReachServer;
  final LocalFileLibrary? _localFiles;

  /// Told which item stopped, how it played and where, once its stop has been
  /// reported, so whatever reacts to a finished episode reads the server's
  /// played state after it.
  final void Function(
    dynamic mediaItem,
    StreamResolutionResult resolution,
    Duration position,
  )?
  _onStopped;

  LocalAwarePlayerService(
    this._inner,
    this._offlineRepo, {
    required bool Function() canReachServer,
    LocalFileLibrary? localFiles,
    void Function(
      dynamic mediaItem,
      StreamResolutionResult resolution,
      Duration position,
    )?
    onStopped,
  }) : _canReachServer = canReachServer,
       _localFiles = localFiles,
       _onStopped = onStopped;

  /// A file opened from outside the app: its position is the library's to
  /// keep, and no server has ever heard of it.
  bool _isLocalFile(dynamic mediaItem) =>
      _localFiles != null && LocalFileLibrary.isLocalFileItem(mediaItem);

  Future<void> _recordLocal(dynamic mediaItem, int positionTicks) async {
    try {
      final itemId = MediaStreamResolver.extractItemId(mediaItem);
      if (_isLocalFile(mediaItem)) {
        await _localFiles!.updatePosition(itemId, positionTicks);
        return;
      }
      await _offlineRepo.updatePlaybackPosition(itemId, positionTicks);
    } catch (_) {}
  }

  Future<void> _forward(Future<void> Function() report) async {
    if (!_canReachServer()) return;

    try {
      await report();
    } catch (_) {}
  }

  @override
  Future<void> onPlaybackStart(
    dynamic mediaItem,
    StreamResolutionResult resolution, {
    int? positionTicks,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    if (_isLocalFile(mediaItem)) return;
    if (!resolution.isLocalMedia) {
      return _inner.onPlaybackStart(
        mediaItem,
        resolution,
        positionTicks: positionTicks,
        audioStreamIndex: audioStreamIndex,
        subtitleStreamIndex: subtitleStreamIndex,
      );
    }
    await _forward(
      () => _inner.onPlaybackStart(
        mediaItem,
        resolution,
        positionTicks: positionTicks,
        audioStreamIndex: audioStreamIndex,
        subtitleStreamIndex: subtitleStreamIndex,
      ),
    );
  }

  @override
  Future<void> onPlaybackProgress(
    dynamic mediaItem,
    StreamResolutionResult resolution,
    Duration position, {
    bool isPaused = false,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int? volumeLevel,
    bool? isMuted,
  }) async {
    if (!resolution.isLocalMedia) {
      return _inner.onPlaybackProgress(
        mediaItem,
        resolution,
        position,
        isPaused: isPaused,
        audioStreamIndex: audioStreamIndex,
        subtitleStreamIndex: subtitleStreamIndex,
        volumeLevel: volumeLevel,
        isMuted: isMuted,
      );
    }
    await _recordLocal(mediaItem, position.inMicroseconds * 10);
    if (_isLocalFile(mediaItem)) return;
    await _forward(
      () => _inner.onPlaybackProgress(
        mediaItem,
        resolution,
        position,
        isPaused: isPaused,
        audioStreamIndex: audioStreamIndex,
        subtitleStreamIndex: subtitleStreamIndex,
        volumeLevel: volumeLevel,
        isMuted: isMuted,
      ),
    );
  }

  @override
  Future<void> onPlaybackStop(
    dynamic mediaItem,
    StreamResolutionResult resolution,
    Duration position, {
    bool releaseLiveStream = true,
  }) async {
    try {
      if (!resolution.isLocalMedia) {
        return await _inner.onPlaybackStop(
          mediaItem,
          resolution,
          position,
          releaseLiveStream: releaseLiveStream,
        );
      }
      await _recordLocal(mediaItem, position.inMicroseconds * 10);
      if (_isLocalFile(mediaItem)) return;
      await _forward(
        () => _inner.onPlaybackStop(
          mediaItem,
          resolution,
          position,
          releaseLiveStream: releaseLiveStream,
        ),
      );
    } finally {
      _onStopped?.call(mediaItem, resolution, position);
    }
  }

  @override
  Future<void> closeLiveStream(String liveStreamId) =>
      _inner.closeLiveStream(liveStreamId);

  @override
  Future<void> stopTranscoding(StreamResolutionResult resolution) async {
    if (resolution.isLocalMedia) return;
    return _inner.stopTranscoding(resolution);
  }

  @override
  void dispose() => _inner.dispose();
}
