import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moonfin/data/services/enhance_purchases.dart';
import 'package:moonfin/data/services/lambent_device_capabilities.dart';
import 'package:moonfin/data/services/lambent_licence.dart';
import 'package:moonfin/data/services/player_licence.dart';

// The vector shared with Lambent Server and the licence service (ENTITLEMENTS.md appendix A.4): TEST seeds of 32 sevens (service),
// nines (player), eights (server).
const player = '_RckOFqgx1tk-3jNYC-h2ZH96_drE8WO1wLqyDXp9hg';
const server = 'E5j2LG0aRXxRumpLXz29L2n8qTIWIY3ImX5Ba9F9k8o';
const ts = 1762100000000;
const lease =
    'eyJ2IjoxLCJob3VzZWhvbGQiOiJfUmNrT0ZxZ3gxdGstM2pOWUMtaDJaSDk2X2RyRThXTzF3THF5RFhwOWhnIiwiYWNjb3VudCI6ImFjY18xIiwiaXNzdWVkX21zIjoxNzYyMTAwMDAwMDAwLCJleHBpcmVzX21zIjoxNzY0NjkyMDAwMDAwLCJlbnRpdGxlbWVudHMiOlt7Im5hbWUiOiJlbmhhbmNlIiwidW50aWxfbXMiOm51bGwsInNvdXJjZSI6InBhZGRsZSJ9XX0.EnLAip_6-Ln4aeq9lpBnBIHVyljMyMSiJ1ybjufvFm1n3JE36UcoZsL8wfpv3NlFCto8WxiqVhLPlN63w2osCg';
const presentSig =
    'RBh9Do-VicN0Nf-OMiih5ZeazOqumVP1FR8CATtub8QSQdHBdn_XeDlwDM4WWGfvq8OqM3omuM6FLz91COnVDQ';
const callSig =
    '4UWC9f_x3vPmPnPlyBxhLzU8CnElkEsR-qcXaiAcRNw7rynKo618BbP-SwRdErU49nwBu4qJ1DmSbvf7LiFABw';
const serviceKey = '6kpsY-KcUgq-9VB7Ey7F-ZVHdq6-vnuSQh7qaRRG0iw';
const day = 24 * 3600 * 1000;

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
Uint8List seedOf(int byte) => Uint8List.fromList(List.filled(32, byte));

/// A lease from the TEST service key.
Future<String> leaseFor(
  String household, {
  int issued = ts,
  int? until,
  String name = 'enhance',
}) async {
  final payload = utf8.encode(
    jsonEncode({
      'v': 1,
      'household': household,
      'account': 'acc_1',
      'issued_ms': issued,
      'expires_ms': issued + 30 * day,
      'entitlements': [
        {'name': name, 'until_ms': until, 'source': 'paddle'},
      ],
    }),
  );
  final algo = Ed25519();
  final sig = await algo.sign(
    payload,
    keyPair: await algo.newKeyPairFromSeed(seedOf(7)),
  );
  return '${b64(payload)}.${b64(sig.bytes)}';
}

/// [lease] shown to [to] by the holder of seed [seed].
Future<LeasePresentation> shown(String lease, String to, int seed, int at) async {
  final algo = Ed25519();
  final sig = await algo.sign(
    utf8.encode(LeasePresentation.message(to, at, lease)),
    keyPair: await algo.newKeyPairFromSeed(seedOf(seed)),
  );
  return LeasePresentation(lease: lease, tsMs: at, to: to, sig: b64(sig.bytes));
}

class MemoryStore implements PlayerLicenceStore {
  MemoryStore([Map<String, String>? values]) : values = values ?? {};
  final Map<String, String> values;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  late int now;
  late List<http.Request> requests;
  late String? serviceLease;

  PlayerLicence make(MemoryStore store) => PlayerLicence(
    store: store,
    serviceKeys: const [serviceKey],
    nowMs: () => now,
    client: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode({'lease': serviceLease}), 200);
    }),
  );

  /// The player whose id is the vector's.
  MemoryStore vectorStore() => MemoryStore({'seed': b64(seedOf(9))});

  setUp(() {
    now = ts;
    requests = [];
    serviceLease = null;
  });

  test('signs what the service and the server expect', () async {
    final licence = make(vectorStore());
    await licence.start();
    expect(licence.id, player);

    expect(await licence.signedBody('/api/v1/lease', ts), jsonEncode({
      'household': player,
      'kind': 'player',
      'sig': callSig,
      'ts_ms': ts,
    }));

    serviceLease = lease;
    await licence.refresh();
    final presented = await licence.presentTo(server);
    expect(presented!.lease, lease);
    expect(presented.sig, presentSig);
  });

  test('says it is a player to the service on start', () async {
    await make(vectorStore()).start();
    final body = jsonDecode(requests.single.body) as Map;
    expect(requests.single.url.path, '/api/v1/lease');
    expect(body['kind'], 'player');
  });

  group('state', () {
    test('a trial of 7 days from first use, then none', () async {
      final store = vectorStore();
      final licence = make(store);
      await licence.start();
      expect(licence.state, EnhanceState.trial);
      expect(licence.source, 'trial');
      expect(licence.until, isNull);
      now = ts + 30 * day;
      expect(licence.state, EnhanceState.trial, reason: 'not started yet');
      licence.startTrial();
      now += 6 * day;
      licence.startTrial();
      expect(licence.state, EnhanceState.trial);
      now += day;
      expect(licence.state, EnhanceState.none);
      // Restarting does not restart it.
      final again = make(store);
      await again.start();
      expect(again.licensed, isFalse);
    });

    test('its own lease, which ends the trial for good', () async {
      serviceLease = lease;
      final store = vectorStore();
      final licence = make(store);
      await licence.start();
      expect(licence.state, EnhanceState.active);
      expect(licence.source, 'paddle');
      expect(licence.until!.millisecondsSinceEpoch, ts + 30 * day);

      now = ts + 30 * day;
      expect(licence.state, EnhanceState.none);
      serviceLease = null;
      final again = make(store);
      await again.start();
      expect(again.licensed, isFalse);
    });

    test('a lease for another household or not the service\'s is ignored', () async {
      serviceLease = await leaseFor(server);
      final licence = make(MemoryStore({'seed': b64(seedOf(9)), 'ever_leased': '1'}));
      await licence.start();
      expect(licence.licensed, isFalse);
    });
  });

  group('a licensed server shows the player its lease', () {
    test('the player is licensed, and keeps it when the server is gone', () async {
      final store = MemoryStore({'seed': b64(seedOf(9)), 'ever_leased': '1'});
      final licence = make(store);
      await licence.start();
      expect(licence.licensed, isFalse);

      final theirs = await leaseFor(server);
      expect(await licence.accept(await shown(theirs, player, 8, now)), isTrue);
      expect(licence.state, EnhanceState.active);
      expect(licence.source, 'server');

      now += 29 * day;
      final later = make(store);
      await later.start();
      expect(later.licensed, isTrue);
      now += 2 * day;
      expect(later.licensed, isFalse);
    });

    test('refused for someone else, stale, by another key, or not paid', () async {
      final licence = make(MemoryStore({'seed': b64(seedOf(9)), 'ever_leased': '1'}));
      await licence.start();
      final theirs = await leaseFor(server);
      expect(await licence.accept(await shown(theirs, 'someone', 8, now)), isFalse);
      expect(await licence.accept(await shown(theirs, player, 8, now - 6 * 60 * 1000)), isFalse);
      expect(await licence.accept(await shown(theirs, player, 3, now)), isFalse);
      final ended = await leaseFor(server, until: now - 1);
      expect(await licence.accept(await shown(ended, player, 8, now)), isFalse);
      final pro = await leaseFor(server, name: 'pro');
      expect(await licence.accept(await shown(pro, player, 8, now)), isFalse);
      expect(licence.licensed, isFalse);
    });

    test('a lease it was shown goes no further', () async {
      final licence = make(MemoryStore({'seed': b64(seedOf(9)), 'ever_leased': '1'}));
      await licence.start();
      await licence.accept(await shown(await leaseFor(server), player, 8, now));
      expect(licence.licensed, isTrue);
      expect(await licence.presentTo('another-server'), isNull);
    });
  });

  group('meeting a server', () {
    EnhancePurchases purchases(
      PlayerLicence player,
      Map<String, dynamic> Function(http.Request) answer,
      List<http.Request> seen,
    ) => EnhancePurchases(
      player: player,
      client: LambentLicenceClient(
        baseUrl: 'http://server',
        client: MockClient((request) async {
          seen.add(request);
          return http.Response(jsonEncode(answer(request)), 200);
        }),
      ),
    );

    Map<String, dynamic> status(String state, {Map<String, Object>? present}) => {
      'household': server,
      'enhance': {'state': state, 'until_ms': null, 'source': null},
      'present': ?present,
    };

    test('a licensed player licenses an unlicensed server', () async {
      serviceLease = lease;
      final licence = make(vectorStore());
      final seen = <http.Request>[];
      final p = purchases(licence, (request) {
        return request.method == 'POST' ? status('active') : status('none');
      }, seen);
      await p.refresh();
      expect(seen.first.url.queryParameters['player'], player);
      expect(seen.last.url.path, '/v1/licence/present');
      final body = jsonDecode(seen.last.body) as Map;
      expect([body['to'], body['sig']], [server, presentSig]);
      expect(p.licence!.enhanced, isTrue);
    });

    test('a licensed server licenses the player', () async {
      final theirs = await leaseFor(server);
      final showing = (await shown(theirs, player, 8, now)).toJson();
      final licence = make(MemoryStore({'seed': b64(seedOf(9)), 'ever_leased': '1'}));
      final seen = <http.Request>[];
      final p = purchases(licence, (_) => status('active', present: showing), seen);
      await p.refresh();
      expect(licence.source, 'server');
      // It holds no lease of its own to show back.
      expect(seen.where((r) => r.method == 'POST'), isEmpty);
    });

    test('a server that is not Lambent is told apart', () async {
      for (final response in [
        http.Response('', 404),
        http.Response('{"error":"unauthorized"}', 401),
        http.Response('<html></html>', 200),
        http.Response('{"Name":"Jellyfin"}', 200),
      ]) {
        final p = EnhancePurchases(
          client: LambentLicenceClient(
            baseUrl: 'http://server',
            client: MockClient((_) async => response),
          ),
        );
        await p.refresh();
        expect(p.isLambentServer, isFalse, reason: response.body);
      }
    });
  });

  group('the home server (section 8.5)', () {
    Map<String, dynamic> body({String? scope, String? home}) => {
      'household': server,
      'enhance': {
        'state': 'active',
        'until_ms': null,
        'source': 'player',
        'scope': ?scope,
        'home': ?home,
      },
    };

    /// A server whose claim answers [claim]; every other call gets [plain].
    EnhancePurchases claimant(
      List<http.Request> seen,
      Map<String, dynamic> plain,
      http.Response Function() claim, {
      EnhanceStore? store,
    }) {
      serviceLease = lease;
      return EnhancePurchases(
        player: make(vectorStore()),
        store: store,
        client: LambentLicenceClient(
          baseUrl: 'http://server',
          client: MockClient((request) async {
            seen.add(request);
            if (request.method == 'POST' &&
                jsonDecode(request.body).containsKey('claim')) {
              return claim();
            }
            return http.Response(jsonEncode(plain), 200);
          }),
        ),
      );
    }

    List<http.Request> claims(List<http.Request> seen) => seen
        .where(
          (r) => r.method == 'POST' && jsonDecode(r.body).containsKey('claim'),
        )
        .toList();

    test('scope and home are read; no scope means the household', () {
      final device = LambentLicence.fromJson(
        body(scope: 'device', home: 'elsewhere'),
      );
      expect(device.scope, EnhanceScope.device);
      expect(device.homeElsewhere, isTrue);
      expect(device.canClaimHome, isTrue);
      expect(device.headline, 'Enhanced on this device');
      expect(device.detail((_) => ''), contains('home server'));
      expect(device.offersPurchase, isTrue);
      final old = LambentLicence.fromJson(body());
      expect(old.scope, EnhanceScope.household);
      expect(old.deviceOnly, isFalse);
      expect(old.canClaimHome, isFalse);
      expect(old.headline, 'Enhanced by your Lambent Server');
      // The server may not have heard yet that the home is elsewhere, so a
      // device-only licence is enough to offer the claim.
      expect(
        LambentLicence.fromJson(body(scope: 'device')).canClaimHome,
        isTrue,
      );
    });

    test(
      'the claim is the player\'s own signature over lambent-home',
      () async {
        serviceLease = lease;
        final licence = make(vectorStore());
        final plain = await licence.presentTo(server);
        expect(plain!.claim, isNull);
        expect(plain.toJson().containsKey('claim'), isFalse);
        final claimed = (await licence.presentTo(server, claim: true))!;
        expect(claimed.sig, presentSig);
        final algo = Ed25519();
        final key = await algo.newKeyPairFromSeed(seedOf(9));
        final publicKey = await key.extractPublicKey();
        List<int> unb64(String v) => base64Url.decode(base64Url.normalize(v));
        expect(
          await algo.verify(
            utf8.encode('lambent-home\n$server\n$ts\n$lease'),
            signature: Signature(unb64(claimed.claim!), publicKey: publicKey),
          ),
          isTrue,
        );
        // Not the ordinary presentation's message.
        expect(
          await algo.verify(
            utf8.encode(LeasePresentation.message(server, ts, lease)),
            signature: Signature(unb64(claimed.claim!), publicKey: publicKey),
          ),
          isFalse,
        );
      },
    );

    test('presenting on a connection never claims', () async {
      final seen = <http.Request>[];
      final p = claimant(
        seen,
        body(scope: 'device', home: 'elsewhere'),
        () => http.Response('{}', 500),
      );
      await p.refresh();
      expect(seen.where((r) => r.method == 'POST'), hasLength(1));
      expect(jsonDecode(seen.last.body).containsKey('claim'), isFalse);
    });

    test('Use this server as my home sends the claim and refreshes', () async {
      final seen = <http.Request>[];
      var moved = false;
      final plain = body(scope: 'device', home: 'elsewhere');
      final p = claimant(seen, plain, () {
        moved = true;
        plain
          ..clear()
          ..addAll(body(scope: 'household'));
        return http.Response(jsonEncode(plain), 200);
      });
      await p.refresh();
      await p.claimHome();
      expect(moved, isTrue);
      final sent = jsonDecode(claims(seen).single.body) as Map;
      expect([sent['to'], sent['sig']], [server, presentSig]);
      expect(sent['claim'], isA<String>());
      expect(p.message, 'This server is now your home.');
      expect(p.busy, isFalse);
    });

    test('a home moved recently says when it can move again', () async {
      final seen = <http.Request>[];
      final p = claimant(
        seen,
        body(scope: 'device', home: 'elsewhere'),
        () => http.Response(
          jsonEncode({
            'error': 'already_linked',
            'retry_ms': 3 * 24 * 3600 * 1000 - 1000,
          }),
          409,
        ),
      );
      await p.refresh();
      await p.claimHome();
      expect(
        p.message,
        'Your home was moved recently. You can move it again in 3 days.',
      );
      expect(p.licence!.canClaimHome, isTrue);
    });

    test('any other failure says the server could not be reached', () async {
      final seen = <http.Request>[];
      final p = claimant(
        seen,
        body(scope: 'device', home: 'elsewhere'),
        // The server's own errors nest the code under `error`.
        () => http.Response(
          '{"error":{"code":"licence_unreachable","message":"the licence service could not be reached"}}',
          502,
        ),
      );
      await p.refresh();
      await p.claimHome();
      expect(p.message, "Your Lambent Server couldn't be reached.");
    });

    test('Restore purchases claims when the player holds a lease', () async {
      final seen = <http.Request>[];
      final store = _CountingStore();
      final p = claimant(
        seen,
        body(scope: 'device', home: 'elsewhere'),
        () => http.Response(jsonEncode(body(scope: 'household')), 200),
        store: store,
      );
      await p.refresh();
      await p.restore();
      expect(claims(seen), hasLength(1));
      expect(store.restores, 1);
    });

    test('Restore purchases sends no claim without a lease', () async {
      final seen = <http.Request>[];
      final store = _CountingStore();
      final p = EnhancePurchases(
        player: make(MemoryStore({'seed': b64(seedOf(9))})),
        store: store,
        client: LambentLicenceClient(
          baseUrl: 'http://server',
          client: MockClient((request) async {
            seen.add(request);
            return http.Response(jsonEncode(body()), 200);
          }),
        ),
      );
      await p.refresh();
      await p.restore();
      expect(seen.where((r) => r.method == 'POST'), isEmpty);
      expect(store.restores, 1);
    });
  });

  test('capabilities name what the device can run', () {
    const all = LambentDeviceCapabilities(ai: true, shader: true, hdr: true);
    expect(all.summary, 'AI upscaling and HDR');
    const shaderOnly = LambentDeviceCapabilities(ai: false, shader: true, hdr: false);
    expect(shaderOnly.summary, 'shader upscaling');
    expect(LambentDeviceCapabilities.none.worthBuying, isFalse);
    expect(shaderOnly.worthBuying, isFalse);
    expect(LambentDeviceCapabilities.fromMap({'hdr': true}).summary, 'HDR');
  });
}

/// A store with nothing in it, which counts how often it was asked to restore.
class _CountingStore implements EnhanceStore {
  int restores = 0;

  @override
  Stream<List<StoreTransaction>> get updates => const Stream.empty();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<EnhanceProduct>> products() async => const [];

  @override
  Future<void> buy(EnhanceProduct product) async {}

  @override
  Future<void> restore() async => restores++;

  @override
  Future<void> finish(StoreTransaction transaction) async {}
}
