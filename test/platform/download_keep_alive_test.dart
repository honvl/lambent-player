import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/platform/download_keep_alive.dart';

void main() {
  group('DownloadBatchProgress', () {
    test('a finished title keeps counting as done', () {
      final batch = DownloadBatchProgress();
      expect(batch.update({'a': 0.9, 'b': 0.1}), closeTo(0.5, 1e-9));
      expect(batch.update({'b': 0.1}), closeTo(0.55, 1e-9));
    });

    test('a queued title lowers the figure until it runs', () {
      final batch = DownloadBatchProgress();
      expect(batch.update({'a': 1.0}), closeTo(1.0, 1e-9));
      expect(batch.update({'a': 1.0, 'b': 0}), closeTo(0.5, 1e-9));
    });

    test('nothing running ends the batch', () {
      final batch = DownloadBatchProgress();
      batch.update({'a': 0.9});
      expect(batch.update({}), 0);
      expect(batch.update({'b': 0.2}), closeTo(0.2, 1e-9));
    });

    test('an unknown progress counts as none', () {
      final batch = DownloadBatchProgress();
      expect(batch.update({'a': -1}), 0);
    });
  });
}
