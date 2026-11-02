import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../util/app_distribution.dart';
import '../../util/platform_detection.dart';
import 'enhance_purchases.dart';
import 'lambent_licence.dart';

/// Lambent Enhance's store products (ENTITLEMENTS.md section 1). The App Store
/// sells two auto-renewable subscriptions in the "Lambent Enhance" group; Play
/// sells one subscription with a monthly and a yearly base plan.
class EnhanceProductIds {
  const EnhanceProductIds._();

  static const appStoreMonthly = 'app.getlambent.player.enhance.monthly';
  static const appStoreYearly = 'app.getlambent.player.enhance.yearly';
  static const play = 'enhance';
  static const playYearlyBasePlan = 'yearly';

  static Set<String> get forThisStore => PlatformDetection.isAndroid
      ? const {play}
      : const {appStoreMonthly, appStoreYearly};
}

/// The App Store or Google Play behind the `in_app_purchase` plugin.
class InAppPurchaseEnhanceStore implements EnhanceStore {
  InAppPurchaseEnhanceStore({InAppPurchase? iap})
    : _iap = iap ?? InAppPurchase.instance;

  final InAppPurchase _iap;
  String? _package;

  /// Store builds only: Play and App Store distributions may sell, and must
  /// sell through their store (Apple 3.1.1, Play billing policy). Sideloaded
  /// and unsigned builds get the server's buy page instead.
  static bool get supported {
    if (PlatformDetection.isAppleTV) return false;
    return switch (AppDistribution.channel) {
      DistributionChannel.aab ||
      DistributionChannel.androidTvAab => PlatformDetection.isAndroid,
      DistributionChannel.iosSigned => PlatformDetection.isIOS,
      _ => false,
    };
  }

  @override
  Stream<List<StoreTransaction>> get updates =>
      _iap.purchaseStream.asyncMap((list) async {
        final package = _package ??= (await PackageInfo.fromPlatform())
            .packageName;
        return [for (final p in list) _transaction(p, package)];
      });

  StoreTransaction _transaction(PurchaseDetails p, String package) {
    final data = p.verificationData.serverVerificationData;
    final StoreProof? proof = data.isEmpty
        ? null
        : PlatformDetection.isAndroid
        ? PlayProof(package: package, product: p.productID, token: data)
        // StoreKit 2: the signed transaction (JWS) the licence service checks
        // with the App Store Server API.
        : AppStoreProof(data);
    return StoreTransaction(
      productId: p.productID,
      status: switch (p.status) {
        PurchaseStatus.pending => StoreTransactionStatus.pending,
        PurchaseStatus.purchased => StoreTransactionStatus.purchased,
        PurchaseStatus.restored => StoreTransactionStatus.restored,
        PurchaseStatus.error => StoreTransactionStatus.error,
        PurchaseStatus.canceled => StoreTransactionStatus.canceled,
      },
      proof: proof,
      needsFinish: p.pendingCompletePurchase,
      handle: p,
    );
  }

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Future<List<EnhanceProduct>> products() async {
    final response = await _iap.queryProductDetails(
      EnhanceProductIds.forThisStore,
    );
    final products = [
      for (final d in response.productDetails)
        EnhanceProduct(
          id: d.id,
          title: d.title,
          price: d.price,
          yearly: _isYearly(d),
          handle: d,
        ),
    ];
    // Monthly first, as the stores list them.
    products.sort((a, b) => (a.yearly ? 1 : 0) - (b.yearly ? 1 : 0));
    return products;
  }

  static bool _isYearly(ProductDetails d) {
    if (d is GooglePlayProductDetails) {
      final index = d.subscriptionIndex;
      final offers = d.productDetails.subscriptionOfferDetails;
      if (index != null && offers != null && index < offers.length) {
        return offers[index].basePlanId ==
            EnhanceProductIds.playYearlyBasePlan;
      }
      return false;
    }
    return d.id == EnhanceProductIds.appStoreYearly;
  }

  @override
  Future<void> buy(EnhanceProduct product) async {
    final details = product.handle! as ProductDetails;
    // Subscriptions are bought as non-consumables; on Play the base plan's
    // offer token rides on the GooglePlayProductDetails.
    await _iap.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: details),
    );
  }

  @override
  Future<void> restore() => _iap.restorePurchases();

  @override
  Future<void> finish(StoreTransaction transaction) =>
      _iap.completePurchase(transaction.handle! as PurchaseDetails);
}
