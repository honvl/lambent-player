import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

class _TestBackend extends Fake
    implements PlayerBackend, EarlyDisplayModeBackend {
  _TestBackend(this.events);

  final List<String> events;

  @override
  Future<void> prepareDisplayMode({
    required double frameRate,
    int? width,
    int? height,
  }) async {
    events.add('prepare $frameRate ${width}x$height');
  }

  @override
  Future<void> releasePreparedDisplayMode() async {
    events.add('release');
  }

  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => const Duration(minutes: 30);
  @override
  Duration get buffer => Duration.zero;
  @override
  bool get isPlaying => false;
  @override
  bool get isBuffering => false;
  @override
  double get playbackSpeed => 1.0;
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration> get durationStream => const Stream<Duration>.empty();
  @override
  Stream<Duration> get bufferStream => const Stream<Duration>.empty();
  @override
  Stream<bool> get playingStream => const Stream<bool>.empty();
  @override
  Stream<bool> get bufferingStream => const Stream<bool>.empty();
  @override
  Stream<bool> get completedStream => const Stream<bool>.empty();
  @override
  Stream<Map<String, dynamic>>? get errorStream => null;
  @override
  bool get supportsRuntimeTrackSelection => true;
  @override
  bool get canRenderBitmapSubtitles => true;
  @override
  bool get requiresStartupMediaReadyCheck => false;
  @override
  bool get nativelyHandlesStartPosition => true;
  @override
  bool get demuxesEmbeddedSubtitles => true;
  @override
  bool get decodesHevcOnlyFromOriginalFile => false;

  @override
  Map<String, dynamic> getDeviceProfile({
    bool useProgressiveTranscode = false,
  }) => <String, dynamic>{};

  @override
  Future<void> play(
    dynamic mediaItem, {
    Duration startPosition = Duration.zero,
  }) async {
    events.add('play');
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> setSubtitleTrack(
    int trackId, {
    bool isBitmapSubtitle = false,
    String? subtitleCodec,
    bool isExternalSubtitle = false,
    String? externalSubtitleUrl,
  }) async {}
  @override
  Future<void> disableSubtitleTrack() async {}
  @override
  Future<void> waitForTracksReady() async {}
  @override
  Future<void> waitForEmbeddedSubtitleCount(int count) async {}
  @override
  Future<void> setAudioTrack(int trackId) async {}
  @override
  Future<void> addExternalSubtitle(
    String url, {
    String? title,
    String? language,
    String? codec,
  }) async {}
  @override
  Future<void> setSubtitleRendererMode(SubtitleRendererMode mode) async {}
  @override
  void dispose() {}
}

class _TestResolver extends MediaStreamResolver {
  _TestResolver(this.events);

  final List<String> events;

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
    events.add('resolve');
    return StreamResolutionResult(
      streamUrl: 'https://example.test/master.m3u8',
      mediaSourceId: 'source-1',
      playSessionId: 'session-1',
      playMethod: StreamPlayMethod.transcode,
      mediaStreams: <Map<String, dynamic>>[
        <String, dynamic>{'Type': 'Video', 'Index': 0, 'Codec': 'hevc'},
      ],
    );
  }
}

/// A queue item the way the app's own items read: a map that also answers
/// `mediaSources`.
class _Movie extends MapBase<String, dynamic> {
  _Movie(this.mediaSources);

  final List<dynamic> mediaSources;
  final Map<String, dynamic> _fields = <String, dynamic>{
    'Id': 'movie-1',
    'Type': 'Movie',
  };

  @override
  dynamic operator [](Object? key) => _fields[key];
  @override
  void operator []=(String key, dynamic value) => _fields[key] = value;
  @override
  void clear() => _fields.clear();
  @override
  Iterable<String> get keys => _fields.keys;
  @override
  dynamic remove(Object? key) => _fields.remove(key);
}

List<dynamic> _sources(Map<String, dynamic> video) => <dynamic>[
  <String, dynamic>{
    'Id': 'source-1',
    'MediaStreams': <dynamic>[
      <String, dynamic>{'Type': 'Audio', 'Index': 1},
      video,
    ],
  },
];

Future<List<String>> _play(WidgetTester tester, _Movie movie) async {
  final events = <String>[];
  final manager = PlaybackManager()
    ..setBackend(_TestBackend(events))
    ..setResolver(_TestResolver(events));
  await manager.playItems(<dynamic>[movie]);
  await tester.pump();
  manager.dispose();
  return events;
}

void main() {
  testWidgets('the title frame rate is asked for before the stream lookup', (
    tester,
  ) async {
    final events = await _play(
      tester,
      _Movie(
        _sources(<String, dynamic>{
          'Type': 'Video',
          'Index': 0,
          'RealFrameRate': 23.976,
          'AverageFrameRate': 23.976,
          'Width': 1920,
          'Height': 1080,
        }),
      ),
    );
    expect(events.take(2), <String>['prepare 23.976 1920x1080', 'resolve']);
  });

  testWidgets('the average rate stands in for a missing real one', (
    tester,
  ) async {
    final events = await _play(
      tester,
      _Movie(
        _sources(<String, dynamic>{
          'Type': 'Video',
          'Index': 0,
          'AverageFrameRate': 25,
        }),
      ),
    );
    expect(events.first, 'prepare 25.0 nullxnull');
  });

  testWidgets('a title without a frame rate asks for nothing', (tester) async {
    final events = await _play(
      tester,
      _Movie(_sources(<String, dynamic>{'Type': 'Video', 'Index': 0})),
    );
    expect(events.where((e) => e.startsWith('prepare')), isEmpty);
  });

  testWidgets('a title without media sources asks for nothing', (
    tester,
  ) async {
    final events = await _play(tester, _Movie(const <dynamic>[]));
    expect(events.where((e) => e.startsWith('prepare')), isEmpty);
    expect(events, contains('resolve'));
  });

  test('an abandoned start hands the display back', () {
    final events = <String>[];
    final manager = PlaybackManager()..setBackend(_TestBackend(events));
    manager.beginPlaybackPreparation();
    manager.cancelPlaybackPreparation();
    expect(events, <String>['release']);
    manager.dispose();
  });
}
