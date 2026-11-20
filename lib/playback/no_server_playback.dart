import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';

/// The server half of playback while no server is signed in: there is
/// nothing to stream, so only what the local-first resolver answers on its
/// own (a file opened from this device) can play.
class NoServerStreamResolver extends MediaStreamResolver {
  @override
  Future<StreamResolutionResult> resolve(
    dynamic mediaItem, {
    Map<String, dynamic>? deviceProfile,
    int? maxStreamingBitrate,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int? startTimeTicks,
    String? mediaSourceId,
    bool enableDirectPlay = true,
    bool enableDirectStream = true,
    bool enableTranscoding = true,
  }) async {
    throw StateError('No server is signed in');
  }
}

/// Play sessions with no server to report them to.
class NoServerPlayerService implements PlayerService {
  @override
  Future<void> onPlaybackStart(
    dynamic mediaItem,
    StreamResolutionResult resolution, {
    int? positionTicks,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {}

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
  }) async {}

  @override
  Future<void> onPlaybackStop(
    dynamic mediaItem,
    StreamResolutionResult resolution,
    Duration position, {
    bool releaseLiveStream = true,
  }) async {}

  @override
  Future<void> closeLiveStream(String liveStreamId) async {}

  @override
  Future<void> stopTranscoding(StreamResolutionResult resolution) async {}

  @override
  void dispose() {}
}

/// What the player gets for a server client while nobody is signed in and a
/// file from this device plays: a server type to read, empty image addresses,
/// and a refusal for every request, which the player's server calls (segments,
/// trickplay, chapters, favourites) already treat as "the server didn't say".
class NoServerClient implements MediaServerClient {
  const NoServerClient();

  @override
  ServerType get serverType => ServerType.jellyfin;

  @override
  String get baseUrl => '';

  @override
  String? get accessToken => null;

  @override
  String? get userId => null;

  @override
  ImageApi get imageApi => const _NoServerImageApi();

  @override
  TrickplayApi? get trickplayApi => null;

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No server is signed in');
}

/// Image addresses for an item no server holds: none.
class _NoServerImageApi implements ImageApi {
  const _NoServerImageApi();

  @override
  dynamic noSuchMethod(Invocation invocation) => '';
}
