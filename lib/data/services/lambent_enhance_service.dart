import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../preference/user_preferences.dart';
import '../../util/lambent_enhancement_defaults.dart';
import '../../util/platform_detection.dart';
import 'enhance_purchases.dart';
import 'enhance_store_iap.dart';
import 'lambent_licence.dart';

/// Lambent Enhance for the server this app is signed in to: one
/// [EnhancePurchases] at a time, rebuilt when the server changes.
///
/// The store is created once, in store builds only, and its purchase updates
/// are listened to from the first server onwards, so a purchase the store
/// re-delivers at launch reaches the server that should confirm it.
class LambentEnhanceService {
  LambentEnhanceService._();
  static final instance = LambentEnhanceService._();

  final EnhanceStore? _store = InAppPurchaseEnhanceStore.supported
      ? InAppPurchaseEnhanceStore()
      : null;

  EnhancePurchases? _current;
  String? _forServer;

  /// The purchases for the signed-in server, started on first use; null
  /// before sign-in.
  EnhancePurchases? get current {
    if (!GetIt.instance.isRegistered<MediaServerClient>()) return null;
    final client = GetIt.instance<MediaServerClient>();
    final base = client.baseUrl;
    if (base.isEmpty) return null;
    if (_current != null && _forServer == base) return _current;
    _current?.dispose();
    _forServer = base;
    final purchases = EnhancePurchases(
      client: LambentLicenceClient(
        baseUrl: base,
        accessToken: client.accessToken,
      ),
      store: _store,
    );
    _current = purchases;
    // A server is held to its licence only once it has answered with one.
    _applyLicence(null);
    purchases.addListener(() {
      if (identical(_current, purchases)) _applyLicence(purchases.licence);
    });
    purchases.start().then((_) {
      // Play hands back purchases it still holds only when asked; StoreKit
      // re-delivers unfinished ones by itself. Forwarding one the server
      // already has is harmless and refreshes its lease.
      if (identical(_current, purchases) &&
          PlatformDetection.isAndroid &&
          purchases.isLambentServer &&
          purchases.store != null) {
        purchases.restore();
      }
    });
    return purchases;
  }

  /// Without Lambent Enhance or a trial the player may only compare
  /// (LambentLicence.mayPlayEnhanced).
  void _applyLicence(LambentLicence? licence) {
    if (!GetIt.instance.isRegistered<UserPreferences>()) return;
    applyLambentLicence(
      compareOnly: licence != null && !licence.mayPlayEnhanced,
      prefs: GetIt.instance<UserPreferences>(),
    );
  }
}
