import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screens/lambent_sample/lambent_sample.dart';
import 'package:moonfin/ui/screens/lambent_sample/lambent_sample_cache.dart';

/// Serves a clip behind a redirect, as getlambent.app/samples/ does, and
/// counts the clip's GETs; [cutShort] sends half and closes the connection.
class _Store {
  late HttpServer server;
  final body = List<int>.generate(300000, (i) => i % 251);
  int gets = 0;
  bool cutShort = false;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      if (path.startsWith('/samples/')) {
        request.response
          ..statusCode = HttpStatus.temporaryRedirect
          ..headers.set(HttpHeaders.locationHeader, '/r2$path');
        await request.response.close();
        return;
      }
      gets++;
      request.response.headers.contentLength = body.length;
      if (cutShort) {
        final socket = await request.response.detachSocket();
        socket.add(body.sublist(0, body.length ~/ 2));
        await socket.flush();
        socket.destroy();
        return;
      }
      request.response.add(body);
      await request.response.close();
    });
  }

  LambentSampleVariant variant(String name) => LambentSampleVariant(
    url: 'http://127.0.0.1:${server.port}/samples/$name',
    hdr: false,
    width: 3840,
    height: 1496,
  );
}

void main() {
  late Directory root;
  late _Store store;
  late LambentSampleCache cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lambent-sample-cache');
    store = _Store();
    await store.start();
    cache = LambentSampleCache(root: () async => root);
  });

  tearDown(() async {
    await store.server.close(force: true);
    await root.delete(recursive: true);
  });

  test('fetches through the redirect once, then plays the kept copy', () async {
    final v = store.variant('lambent-sample-v2-tv-sdr.mp4');
    final progress = <double>[];
    final path = await cache.fetch(v, onProgress: progress.add);
    expect(await File(path).readAsBytes(), store.body);
    expect(progress.last, 1.0);
    expect(store.gets, 1);

    final again = await LambentSampleCache(root: () async => root).fetch(v);
    expect(again, path);
    expect(store.gets, 1, reason: 'a whole copy is never fetched again');
  });

  test('a fetch cut short leaves nothing behind and fetches again', () async {
    final v = store.variant('lambent-sample-v2-tv-sdr.mp4');
    store.cutShort = true;
    await expectLater(cache.fetch(v), throwsA(anything));
    final left = await Directory('${root.path}/lambent-sample').list().toList();
    expect(left, isEmpty);

    store.cutShort = false;
    final path = await cache.fetch(v);
    expect(await File(path).length(), store.body.length);
  });

  test('prune keeps only the encodes this version plays', () async {
    final dir = Directory('${root.path}/lambent-sample');
    await dir.create(recursive: true);
    final kept = LambentSampleCache.fileName(LambentSample.phoneSdr1920);
    for (final name in [kept, 'lambent-sample-v1-sdr-1920.mp4', '$kept.part']) {
      await File('${dir.path}/$name').writeAsString('x');
    }
    await cache.prune();
    final names = [
      for (final e in await dir.list().toList()) e.uri.pathSegments.last,
    ];
    expect(names, [kept]);
  });

  test('every variant the screen can pick is kept by prune', () {
    final picked = LambentSample.order(
      hdrScreen: true,
      hevcHdr10: true,
      bigScreen: true,
    );
    expect(LambentSample.all.toSet(), picked.toSet());
  });
}
