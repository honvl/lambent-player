import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/enhance_purchases.dart';
import 'package:moonfin/data/services/lambent_licence.dart';

/// Lambent Server's two licence routes, on a real loopback socket.
class FakeLambentServer {
  late HttpServer _server;
  Map<String, dynamic> licence = {
    'enhance': {'state': 'none', 'until_ms': null, 'source': null},
    'pro_on_this_household': false,
    'buy_url': 'https://getlambent.vercel.app/buy?household=abc',
  };

  /// What `POST /v1/licence/store` answers next: 200 with the new licence, or
  /// this status with an error body.
  int storeStatus = 200;
  bool hasLicenceRoute = true;
  final List<Map<String, dynamic>> forwarded = [];
  final List<String?> tokens = [];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    tokens.add(request.headers.value('X-Emby-Token'));
    final response = request.response
      ..headers.contentType = ContentType.json;
    final path = request.uri.path;
    if (!hasLicenceRoute) {
      response.statusCode = 404;
    } else if (request.method == 'GET' && path == '/v1/licence') {
      response.write(jsonEncode(licence));
    } else if (request.method == 'POST' && path == '/v1/licence/store') {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      forwarded.add(body);
      if (storeStatus == 200) {
        licence = {
          ...licence,
          'enhance': {
            'state': 'active',
            'until_ms': 1793636000000,
            'source': body['store'],
          },
        };
        response.write(jsonEncode(licence));
      } else {
        response.statusCode = storeStatus;
        response.write(
          jsonEncode({
            'error': storeStatus == 502 ? 'service_unreachable' : 'invalid',
            'message': storeStatus == 502
                ? 'The licence service could not be reached.'
                : 'The transaction is not for this app.',
          }),
        );
      }
    } else {
      response.statusCode = 404;
    }
    await response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

class FakeStore implements EnhanceStore {
  final _updates = StreamController<List<StoreTransaction>>.broadcast();
  final List<StoreTransaction> finished = [];
  final List<String> bought = [];
  int restores = 0;

  void deliver(List<StoreTransaction> transactions) =>
      _updates.add(transactions);

  @override
  Stream<List<StoreTransaction>> get updates => _updates.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<EnhanceProduct>> products() async => const [
    EnhanceProduct(
      id: 'app.getlambent.player.enhance.monthly',
      title: 'Lambent Enhance',
      price: r'$4.99',
      yearly: false,
    ),
    EnhanceProduct(
      id: 'app.getlambent.player.enhance.yearly',
      title: 'Lambent Enhance',
      price: r'$39.99',
      yearly: true,
    ),
  ];

  @override
  Future<void> buy(EnhanceProduct product) async => bought.add(product.id);

  @override
  Future<void> restore() async => restores++;

  @override
  Future<void> finish(StoreTransaction transaction) async =>
      finished.add(transaction);
}

StoreTransaction purchased(StoreProof proof, {Object? handle}) =>
    StoreTransaction(
      productId: 'app.getlambent.player.enhance.monthly',
      status: StoreTransactionStatus.purchased,
      proof: proof,
      needsFinish: true,
      handle: handle ?? Object(),
    );

/// Lets the listener run its awaits to the end.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late FakeLambentServer server;
  late FakeStore store;
  late EnhancePurchases purchases;

  setUp(() async {
    server = FakeLambentServer();
    await server.start();
    store = FakeStore();
    purchases = EnhancePurchases(
      client: LambentLicenceClient(
        baseUrl: server.baseUrl,
        accessToken: 'tok',
      ),
      store: store,
    );
  });

  tearDown(() async {
    purchases.dispose();
    await server.stop();
  });

  group('LambentLicence', () {
    test('reads every state and the buy page', () {
      final licence = LambentLicence.fromJson({
        'enhance': {
          'state': 'trial',
          'until_ms': 1762100000000,
          'source': null,
        },
        'pro_on_this_household': true,
        'buy_url': 'https://getlambent.vercel.app/buy?household=abc',
      });
      expect(licence.enhance, EnhanceState.trial);
      expect(licence.enhanced, isTrue);
      expect(licence.until, DateTime.fromMillisecondsSinceEpoch(1762100000000));
      expect(licence.proOnHousehold, isTrue);
      expect(licence.buyUrl?.host, 'getlambent.vercel.app');
      expect(
        LambentLicence.fromJson({
          'enhance': {'state': 'preview'},
        }).headline,
        "Your server doesn't have Lambent Enhance",
      );
      expect(LambentLicence.fromJson({}).enhance, EnhanceState.none);
    });

    test('store proofs match section 7', () {
      expect(const AppStoreProof('jws').toJson(), {
        'store': 'app_store',
        'transaction': 'jws',
      });
      expect(
        const PlayProof(
          package: 'app.getlambent.player',
          product: 'enhance',
          token: 't',
        ).toJson(),
        {
          'store': 'play',
          'package': 'app.getlambent.player',
          'product': 'enhance',
          'token': 't',
        },
      );
    });
  });

  test('only active and trial may play enhanced full screen', () {
    LambentLicence of(String state) => LambentLicence.fromJson({
      'enhance': {'state': state},
    });
    expect(of('active').mayPlayEnhanced, isTrue);
    expect(of('trial').mayPlayEnhanced, isTrue);
    expect(of('preview').mayPlayEnhanced, isFalse);
    expect(of('none').mayPlayEnhanced, isFalse);
  });

  test('loads the licence and products, sending the session token', () async {
    await purchases.start();
    expect(purchases.isLambentServer, isTrue);
    expect(purchases.licence?.enhance, EnhanceState.none);
    expect(purchases.products, hasLength(2));
    expect(purchases.canBuyInApp, isTrue);
    expect(server.tokens.first, 'tok');
  });

  test('a server without the licence route is not a Lambent Server', () async {
    server.hasLicenceRoute = false;
    await purchases.start();
    expect(purchases.isLambentServer, isFalse);
    expect(purchases.licence, isNull);
    expect(purchases.products, isEmpty);
  });

  test('a purchase is forwarded, then finished once confirmed', () async {
    await purchases.start();
    store.deliver([purchased(const AppStoreProof('jws-1'))]);
    await settle();
    expect(server.forwarded, [
      {'store': 'app_store', 'transaction': 'jws-1'},
    ]);
    expect(store.finished, hasLength(1));
    expect(purchases.licence?.enhance, EnhanceState.active);
    expect(purchases.licence?.source, 'app_store');
    expect(purchases.unconfirmedCount, 0);
  });

  test('a Play purchase forwards package, product and token', () async {
    await purchases.start();
    store.deliver([
      purchased(
        const PlayProof(
          package: 'app.getlambent.player',
          product: 'enhance',
          token: 'play-token',
        ),
      ),
    ]);
    await settle();
    expect(server.forwarded.single, {
      'store': 'play',
      'package': 'app.getlambent.player',
      'product': 'enhance',
      'token': 'play-token',
    });
    expect(store.finished, hasLength(1));
  });

  test('stays unfinished while the server cannot reach the service, '
      'and is finished on a later retry', () async {
    await purchases.start();
    server.storeStatus = 502;
    store.deliver([purchased(const AppStoreProof('jws-2'))]);
    await settle();
    expect(store.finished, isEmpty);
    expect(purchases.unconfirmedCount, 1);
    expect(purchases.message, contains('safe'));
    expect(purchases.licence?.enhance, EnhanceState.none);

    server.storeStatus = 200;
    await purchases.retryUnconfirmed();
    expect(store.finished, hasLength(1));
    expect(purchases.unconfirmedCount, 0);
    expect(purchases.licence?.enhance, EnhanceState.active);
  });

  test('stays unfinished when the server is unreachable', () async {
    await purchases.start();
    await server.stop();
    store.deliver([purchased(const AppStoreProof('jws-3'))]);
    await settle();
    expect(store.finished, isEmpty);
    expect(purchases.unconfirmedCount, 1);
    // Restart so tearDown can stop it again.
    await server.start();
  });

  test('a refused purchase is left open and says why', () async {
    await purchases.start();
    server.storeStatus = 400;
    store.deliver([purchased(const AppStoreProof('bad'))]);
    await settle();
    expect(store.finished, isEmpty);
    expect(purchases.message, contains('not for this app'));
  });

  test('a store re-delivering the same open purchase is counted once', () async {
    await purchases.start();
    server.storeStatus = 502;
    final handle = Object();
    store.deliver([purchased(const AppStoreProof('jws-4'), handle: handle)]);
    await settle();
    store.deliver([purchased(const AppStoreProof('jws-4'), handle: handle)]);
    await settle();
    expect(purchases.unconfirmedCount, 1);
  });

  test('cancelled and failed purchases are finished without the server',
      () async {
    await purchases.start();
    store.deliver(const [
      StoreTransaction(
        productId: 'x',
        status: StoreTransactionStatus.canceled,
        needsFinish: true,
      ),
      StoreTransaction(
        productId: 'x',
        status: StoreTransactionStatus.error,
        needsFinish: true,
      ),
    ]);
    await settle();
    expect(server.forwarded, isEmpty);
    expect(store.finished, hasLength(2));
    expect(purchases.busy, isFalse);
  });

  test('without a store there is nothing to buy in the app', () async {
    final sideloaded = EnhancePurchases(
      client: LambentLicenceClient(baseUrl: server.baseUrl),
    );
    await sideloaded.start();
    expect(sideloaded.canBuyInApp, isFalse);
    expect(sideloaded.licence?.buyUrl, isNotNull);
    sideloaded.dispose();
  });
}
