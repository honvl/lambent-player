import 'dart:async';

import 'package:flutter/services.dart';

import '../../util/app_distribution.dart';
import '../../util/platform_detection.dart';
import 'enhance_purchases.dart';
import 'enhance_store_iap.dart';
import 'lambent_licence.dart';

/// The App Store on Apple TV. The `in_app_purchase` plugin has no tvOS side,
/// so this talks to StoreKit 2 through the app's own channel
/// (tvos/Runner/AppleTvStoreChannel.swift). It sells the same three products
/// as the iPhone and iPad builds, and hands every transaction on as its
/// signed form (JWS) for the licence service to check with Apple.
class AppleTvEnhanceStore implements EnhanceStore {
  AppleTvEnhanceStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('lambent/store') {
    _channel.setMethodCallHandler(_onCall);
    _updates = StreamController<List<StoreTransaction>>.broadcast(
      // StoreKit hands back unfinished transactions as soon as it is asked,
      // so ask only once something is there to take them.
      onListen: () => _channel.invokeMethod<void>('listen'),
    );
  }

  final MethodChannel _channel;
  late final StreamController<List<StoreTransaction>> _updates;

  /// One handle object per transaction id: [EnhancePurchases] tells a
  /// re-delivered transaction from a new one by its handle's identity.
  final Map<String, String> _handles = {};

  /// App Store builds only (Apple 3.1.1); a sideloaded Apple TV build has no
  /// store to sell through.
  static bool get supported =>
      PlatformDetection.isAppleTV &&
      AppDistribution.channel == DistributionChannel.iosSigned;

  @override
  Stream<List<StoreTransaction>> get updates => _updates.stream;

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'update') return;
    final update = (call.arguments as Map).cast<String, Object?>();
    final id = update['id'] as String?;
    final jws = update['jws'] as String?;
    _updates.add([
      StoreTransaction(
        productId: update['productId']! as String,
        status: switch (update['status']) {
          'pending' => StoreTransactionStatus.pending,
          'purchased' => StoreTransactionStatus.purchased,
          'restored' => StoreTransactionStatus.restored,
          'canceled' => StoreTransactionStatus.canceled,
          _ => StoreTransactionStatus.error,
        },
        proof: jws == null || jws.isEmpty ? null : AppStoreProof(jws),
        // Only a real transaction is held open by StoreKit; a cancel or an
        // error has none.
        needsFinish: id != null,
        handle: id == null ? null : _handles.putIfAbsent(id, () => id),
        id: id,
      ),
    ]);
  }

  @override
  Future<bool> isAvailable() async =>
      await _channel.invokeMethod<bool>('isAvailable') ?? false;

  @override
  Future<List<EnhanceProduct>> products() async {
    final found = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'products',
      {'ids': EnhanceProductIds.forThisStore.toList()},
    );
    final products = [
      for (final p in found ?? const <Map<Object?, Object?>>[])
        EnhanceProduct(
          id: p['id']! as String,
          title: p['title'] as String? ?? '',
          price: p['price'] as String? ?? '',
          yearly: p['id'] == EnhanceProductIds.appStoreYearly,
          lifetime: p['id'] == EnhanceProductIds.appStoreLifetime,
        ),
    ];
    // Monthly first, as the App Store lists them, then lifetime.
    int rank(EnhanceProduct p) => p.lifetime ? 2 : (p.yearly ? 1 : 0);
    products.sort((a, b) => rank(a) - rank(b));
    return products;
  }

  @override
  Future<void> buy(EnhanceProduct product) =>
      _channel.invokeMethod<void>('buy', {'id': product.id});

  @override
  Future<void> restore() => _channel.invokeMethod<void>('restore');

  @override
  Future<void> finish(StoreTransaction transaction) async {
    final id = transaction.id;
    if (id == null) return;
    await _channel.invokeMethod<void>('finish', {'id': id});
    _handles.remove(id);
  }
}
