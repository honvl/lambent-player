import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/util/lambent_server.dart';
import 'package:server_core/server_core.dart';

class _Client extends Mock implements MediaServerClient {}

class _SystemApi extends Mock implements SystemApi {}

void main() {
  (MediaServerClient, _SystemApi) jellyfin() {
    final client = _Client();
    final system = _SystemApi();
    when(() => client.serverType).thenReturn(ServerType.jellyfin);
    when(() => client.systemApi).thenReturn(system);
    return (client, system);
  }

  test('Lambent Server has no SyncPlay', () async {
    final (client, system) = jellyfin();
    when(
      system.getPublicSystemInfo,
    ).thenAnswer((_) async => {'Id': '6c616d62ac0b20150000000000000000'});

    final kind = ActiveServerKind();
    await kind.refresh(client);

    expect(kind.hasSyncPlay, isFalse);
  });

  test('a real Jellyfin server has it, once it has answered', () async {
    final (client, system) = jellyfin();
    final answer = Completer<Map<String, dynamic>>();
    when(system.getPublicSystemInfo).thenAnswer((_) => answer.future);

    final kind = ActiveServerKind();
    var told = 0;
    kind.addListener(() => told++);
    final refreshing = kind.refresh(client);
    expect(kind.hasSyncPlay, isFalse);

    answer.complete({'Id': '0123456789abcdef0123456789abcdef'});
    await refreshing;

    expect(kind.hasSyncPlay, isTrue);
    expect(told, 1);
  });

  test('a server that does not answer stays without it', () async {
    final (client, system) = jellyfin();
    when(system.getPublicSystemInfo).thenThrow(Exception('offline'));

    final kind = ActiveServerKind();
    await kind.refresh(client);

    expect(kind.hasSyncPlay, isFalse);
  });

  test('another server type is not asked', () async {
    final client = _Client();
    when(() => client.serverType).thenReturn(ServerType.plex);

    final kind = ActiveServerKind();
    await kind.refresh(client);

    expect(kind.hasSyncPlay, isTrue);
    verifyNever(() => client.systemApi);
  });

  test('a slow answer from the old server does not count', () async {
    final (old, oldSystem) = jellyfin();
    final oldAnswer = Completer<Map<String, dynamic>>();
    when(oldSystem.getPublicSystemInfo).thenAnswer((_) => oldAnswer.future);
    final (current, currentSystem) = jellyfin();
    when(
      currentSystem.getPublicSystemInfo,
    ).thenAnswer((_) async => {'Id': '6c616d62ac0b20150000000000000000'});

    final kind = ActiveServerKind();
    final slow = kind.refresh(old);
    await kind.refresh(current);
    oldAnswer.complete({'Id': '0123456789abcdef0123456789abcdef'});
    await slow;

    expect(kind.hasSyncPlay, isFalse);
  });
}
