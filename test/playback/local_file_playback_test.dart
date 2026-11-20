import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

import 'package:moonfin/data/local_files/local_file_library.dart';
import 'package:moonfin/data/repositories/offline_repository.dart';
import 'package:moonfin/playback/local_aware_player_service.dart';
import 'package:moonfin/playback/local_first_media_stream_resolver.dart';
import 'package:moonfin/playback/offline_stream_resolver.dart';

const _fileId = '${LocalFileLibrary.idPrefix}1';

final _file = LocalFile(
  id: _fileId,
  name: 'Golden Sea (test).mkv',
  bookmark: Uint8List.fromList([1, 2, 3]),
  size: 21401843,
  owned: false,
  addedAt: DateTime(2026, 11, 17),
  positionTicks: 600000000,
  runTimeTicks: 1800000000,
  mediaStreams: const [
    {'Index': 0, 'Type': 'Video', 'Codec': 'h264'},
    {'Index': 1, 'Type': 'Audio', 'Codec': 'aac', 'Language': 'eng'},
    {'Index': 3, 'Type': 'Subtitle', 'Codec': 'subrip', 'Language': 'eng'},
  ],
);

class _Library extends Fake implements LocalFileLibrary {
  _Library({this.gone = false});

  final bool gone;
  final positions = <String, int>{};
  final released = <String>[];

  @override
  Future<OpenedLocalFile?> open(String id) async =>
      gone ? null : OpenedLocalFile(_file, '/private/var/mobile/Golden Sea (test).mkv');

  @override
  Future<void> release(String path) async => released.add(path);

  @override
  Future<void> updatePosition(String id, int positionTicks) async =>
      positions[id] = positionTicks;
}

class _Server extends MediaStreamResolver {
  int asked = 0;

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
    asked++;
    return const StreamResolutionResult(
      streamUrl: 'https://server/movie',
      mediaSourceId: 'movie',
      playMethod: StreamPlayMethod.directPlay,
    );
  }
}

class _Downloads extends Fake implements OfflineStreamResolver {
  @override
  Future<OfflineStreamResult?> resolve(String itemId) async => null;
}

class _PlaySessions extends Fake implements PlayerService {
  final reports = <String>[];

  @override
  Future<void> onPlaybackStart(
    dynamic mediaItem,
    StreamResolutionResult resolution, {
    int? positionTicks,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async => reports.add('start');

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
  }) async => reports.add('progress');

  @override
  Future<void> onPlaybackStop(
    dynamic mediaItem,
    StreamResolutionResult resolution,
    Duration position, {
    bool releaseLiveStream = true,
  }) async => reports.add('stop');
}

class _Offline extends Fake implements OfflineRepository {
  @override
  Future<void> updatePlaybackPosition(String itemId, int positionTicks) async {
    fail('a local file is not a download');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const item = {'Id': _fileId};

  group('resolving a file opened from outside the app', () {
    test('plays the file in place with its probed tracks', () async {
      final server = _Server();
      final result = await LocalFirstMediaStreamResolver(
        inner: server,
        offline: _Downloads(),
        localFiles: _Library(),
      ).resolve(item);

      expect(result.isLocalMedia, isTrue);
      expect(result.streamUrl, '/private/var/mobile/Golden Sea (test).mkv');
      expect(result.container, 'mkv');
      expect(result.mediaStreams, _file.mediaStreams);
      expect(server.asked, 0);
    });

    test('a file that is gone fails instead of asking the server', () async {
      final server = _Server();
      final resolver = LocalFirstMediaStreamResolver(
        inner: server,
        offline: _Downloads(),
        localFiles: _Library(gone: true),
      );

      await expectLater(resolver.resolve(item), throwsStateError);
      expect(server.asked, 0);
    });

    test('a server item still goes to the server', () async {
      final server = _Server();
      await LocalFirstMediaStreamResolver(
        inner: server,
        offline: _Downloads(),
        localFiles: _Library(),
      ).resolve(const {'Id': 'movie'});

      expect(server.asked, 1);
    });
  });

  group('progress of a local file', () {
    const resolution = StreamResolutionResult(
      streamUrl: '/private/var/mobile/Golden Sea (test).mkv',
      mediaSourceId: _fileId,
      playMethod: StreamPlayMethod.directPlay,
      isLocalMedia: true,
    );

    test('stays on the device and never reaches the server', () async {
      final library = _Library();
      final sessions = _PlaySessions();
      final service = LocalAwarePlayerService(
        sessions,
        _Offline(),
        canReachServer: () => true,
        localFiles: library,
      );

      await service.onPlaybackStart(item, resolution);
      await service.onPlaybackProgress(
        item,
        resolution,
        const Duration(minutes: 1),
      );
      await service.onPlaybackStop(
        item,
        resolution,
        const Duration(minutes: 2),
      );

      expect(sessions.reports, isEmpty);
      expect(library.positions[_fileId], 1200000000);
    });
  });

  group('LocalFile', () {
    test('survives a round trip through the stored list', () {
      final back = LocalFile.fromJson(_file.toJson())!;
      expect(back.id, _file.id);
      expect(back.bookmark, _file.bookmark);
      expect(back.positionTicks, _file.positionTicks);
      expect(back.mediaStreams, _file.mediaStreams);
    });

    test('plays as a home video, not a film', () {
      final item = LocalFileLibrary().itemFor(_file);
      expect(item.id, _fileId);
      expect(item.type, 'Video');
      expect(item.name, 'Golden Sea (test)');
      expect(
        (item.rawData['UserData'] as Map)['PlaybackPositionTicks'],
        600000000,
      );
      expect(LocalFileLibrary.isLocalFileItem(item), isTrue);
      expect(LocalFileLibrary.isLocalFileItem(const {'Id': 'movie'}), isFalse);
    });
  });
}
