import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'lambent_sample.dart';

/// Keeps each sample encode in the app's cache once it has been fetched. The
/// players read a URL again from the network on every loop (Media3 has no disk
/// cache here, AetherEngine seeks the HTTP stream back to the start), which
/// sent a 30-65 MB clip every 64 seconds for as long as the screen was open.
/// The screen now plays the kept file, and a later visit needs no network.
class LambentSampleCache {
  LambentSampleCache({Dio? dio, Future<Directory> Function()? root})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: stall,
              // Between bytes received, not for the whole clip.
              receiveTimeout: stall,
            ),
          ),
      _root = root ?? getApplicationCacheDirectory;

  /// A fetch that receives nothing for this long fails over to the next
  /// variant, like a player that never starts.
  static const stall = Duration(seconds: 20);

  final Dio _dio;
  final Future<Directory> Function() _root;
  final _cancel = CancelToken();

  static String fileName(LambentSampleVariant variant) =>
      Uri.parse(variant.url).pathSegments.last;

  Future<Directory> _dir() async {
    final dir = Directory('${(await _root()).path}/lambent-sample');
    await dir.create(recursive: true);
    return dir;
  }

  /// Deletes unfinished fetches and encodes this version no longer plays.
  Future<void> prune() async {
    final keep = {for (final v in LambentSample.all) fileName(v)};
    final dir = await _dir();
    await for (final entry in dir.list()) {
      if (entry is! File || keep.contains(entry.uri.pathSegments.last)) {
        continue;
      }
      try {
        await entry.delete();
      } catch (_) {}
    }
  }

  /// The path of a whole local copy of [variant], fetched first unless one is
  /// kept. [onProgress] hears 0-1 while it is fetched. A fetch is written
  /// beside the copy and renamed only once every byte has arrived, so a copy
  /// that exists is always whole.
  Future<String> fetch(
    LambentSampleVariant variant, {
    void Function(double fraction)? onProgress,
  }) async {
    final dir = await _dir();
    final file = File('${dir.path}/${fileName(variant)}');
    if (await file.exists() && await file.length() > 0) return file.path;
    final part = File('${file.path}.part');
    try {
      final response = await _dio.download(
        variant.url,
        part.path,
        cancelToken: _cancel,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
      );
      final expected = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      final got = await part.length();
      if (got == 0 || (expected != null && got != expected)) {
        throw StateError('fetched $got of ${expected ?? '?'} bytes');
      }
      await part.rename(file.path);
      return file.path;
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Stops a fetch under way; it fails with a cancelled error.
  void cancel() {
    if (!_cancel.isCancelled) _cancel.cancel();
  }
}
