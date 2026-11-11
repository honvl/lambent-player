import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/enhance_purchases.dart';
import 'package:moonfin/data/services/enhance_store_iap.dart';
import 'package:moonfin/data/services/enhance_store_tvos.dart';
import 'package:moonfin/data/services/lambent_licence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('lambent/store');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'isAvailable' => true,
        'products' => [
          {
            'id': EnhanceProductIds.appStoreLifetime,
            'title': 'Lifetime',
            'price': r'$79.99',
          },
          {
            'id': EnhanceProductIds.appStoreYearly,
            'title': 'Yearly',
            'price': r'$39.99',
          },
          {
            'id': EnhanceProductIds.appStoreMonthly,
            'title': 'Monthly',
            'price': r'$4.99',
          },
        ],
        _ => null,
      };
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// What the Swift side sends for one transaction or purchase result.
  Future<void> native(Map<String, Object?> update) =>
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall('update', update)),
        (_) {},
      );

  test('lists monthly, yearly, then lifetime, at the store\'s prices', () async {
    final store = AppleTvEnhanceStore(channel: channel);
    expect(await store.isAvailable(), isTrue);
    final products = await store.products();
    expect(products.map((p) => p.id), [
      EnhanceProductIds.appStoreMonthly,
      EnhanceProductIds.appStoreYearly,
      EnhanceProductIds.appStoreLifetime,
    ]);
    expect(products.map((p) => p.price), [r'$4.99', r'$39.99', r'$79.99']);
    expect(products[1].yearly, isTrue);
    expect(products[2].lifetime, isTrue);
    final asked = calls.singleWhere((c) => c.method == 'products');
    expect(
      (asked.arguments as Map)['ids'],
      unorderedEquals(EnhanceProductIds.forThisStore),
    );
  });

  test('asks StoreKit for transactions only once someone listens', () async {
    final store = AppleTvEnhanceStore(channel: channel);
    expect(calls.where((c) => c.method == 'listen'), isEmpty);
    final seen = <StoreTransaction>[];
    final sub = store.updates.listen(seen.addAll);
    await pumpEventQueue();
    expect(calls.where((c) => c.method == 'listen'), hasLength(1));
    await sub.cancel();
  });

  test('a transaction carries its JWS and is finished by its id', () async {
    final store = AppleTvEnhanceStore(channel: channel);
    final seen = <StoreTransaction>[];
    final sub = store.updates.listen(seen.addAll);
    await native({
      'productId': EnhanceProductIds.appStoreYearly,
      'status': 'purchased',
      'jws': 'signed.transaction.jws',
      'id': '2000000123456789',
    });
    // StoreKit 2 delivers a purchase a second time, as a transaction update.
    await native({
      'productId': EnhanceProductIds.appStoreYearly,
      'status': 'purchased',
      'jws': 'signed.transaction.jws',
      'id': '2000000123456789',
    });
    await pumpEventQueue();
    expect(seen, hasLength(2));
    final t = seen.first;
    expect(t.status, StoreTransactionStatus.purchased);
    expect(t.needsFinish, isTrue);
    expect(t.id, '2000000123456789');
    expect((t.proof! as AppStoreProof).transaction, 'signed.transaction.jws');
    expect(identical(seen[0].handle, seen[1].handle), isTrue);

    await store.finish(t);
    final finish = calls.singleWhere((c) => c.method == 'finish');
    expect((finish.arguments as Map)['id'], '2000000123456789');
    await sub.cancel();
  });

  test('a cancel or an error has nothing to finish or forward', () async {
    final store = AppleTvEnhanceStore(channel: channel);
    final seen = <StoreTransaction>[];
    final sub = store.updates.listen(seen.addAll);
    await native({
      'productId': EnhanceProductIds.appStoreMonthly,
      'status': 'canceled',
    });
    await native({
      'productId': EnhanceProductIds.appStoreMonthly,
      'status': 'error',
    });
    await pumpEventQueue();
    expect(seen.map((t) => t.status), [
      StoreTransactionStatus.canceled,
      StoreTransactionStatus.error,
    ]);
    expect(seen.every((t) => !t.needsFinish && t.proof == null), isTrue);
    await store.finish(seen.first);
    expect(calls.where((c) => c.method == 'finish'), isEmpty);
    await sub.cancel();
  });

  test('buying and restoring go to StoreKit', () async {
    final store = AppleTvEnhanceStore(channel: channel);
    final products = await store.products();
    await store.buy(products.first);
    await store.restore();
    final buy = calls.singleWhere((c) => c.method == 'buy');
    expect((buy.arguments as Map)['id'], EnhanceProductIds.appStoreMonthly);
    expect(calls.where((c) => c.method == 'restore'), hasLength(1));
  });
}
