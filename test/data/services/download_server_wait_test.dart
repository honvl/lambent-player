import 'package:background_downloader/background_downloader.dart' as bgd;
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/models/download_quality.dart';
import 'package:moonfin/data/services/download_service.dart';

/// A download whose connection drops, leaving home with the film half
/// fetched, waits for the server and resumes instead of starting over.
void main() {
  bool wait(
    bgd.TaskException? exception, {
    bool resumable = true,
    int waits = 0,
  }) => shouldWaitForServer(
    resumable: resumable,
    exception: exception,
    waitsSoFar: waits,
  );

  test('a dropped connection on an original waits for the server', () {
    expect(
      wait(bgd.TaskConnectionException('The network connection was lost.')),
      isTrue,
    );
    expect(wait(bgd.TaskConnectionException('The request timed out.')), isTrue);
    expect(
      wait(null),
      isTrue,
      reason: 'no exception and no answer: the network',
    );
  });

  test('a transcode, which cannot resume, fails as before', () {
    expect(
      wait(bgd.TaskConnectionException('lost'), resumable: false),
      isFalse,
    );
  });

  test('anything but the connection fails at once', () {
    expect(wait(bgd.TaskHttpException('Not Found', 404)), isFalse);
    expect(
      wait(bgd.TaskFileSystemException('No space left on device')),
      isFalse,
    );
    expect(wait(bgd.TaskUrlException('bad url')), isFalse);
    expect(
      wait(bgd.TaskConnectionException('SSL handshake failed: certificate')),
      isFalse,
      reason: 'a refused certificate goes to the legacy engine instead',
    );
  });

  test('a connection that keeps dropping fails in the end', () {
    expect(wait(null, waits: maxServerWaits - 1), isTrue);
    expect(wait(null, waits: maxServerWaits), isFalse);
  });

  test('the waiting line survives a copy and clears with the next one', () {
    const progress = DownloadProgress(
      itemId: 'i',
      fileName: 'Film',
      progress: 0.4,
      bytesPerSecond: 1000,
      etaSeconds: 9,
      quality: DownloadQuality.original,
    );
    final waiting = progress.copyWith(
      isWaitingForServer: true,
      clearRate: true,
    );
    expect(waiting.isWaitingForServer, isTrue);
    expect(waiting.isInFlight, isTrue, reason: 'still listed as downloading');
    expect((waiting.bytesPerSecond, waiting.etaSeconds), (null, null));
    expect(waiting.copyWith(progress: 0.5).isWaitingForServer, isTrue);
    expect(
      waiting.copyWith(isWaitingForServer: false).isWaitingForServer,
      isFalse,
    );
  });
}
