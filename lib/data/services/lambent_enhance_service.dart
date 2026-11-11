import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../preference/user_preferences.dart';
import '../../util/lambent_enhancement_defaults.dart';
import '../../util/platform_detection.dart';
import 'enhance_purchases.dart';
import 'enhance_store_iap.dart';
import 'enhance_store_tvos.dart';
import 'lambent_licence.dart';
import 'player_licence.dart';

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
      : AppleTvEnhanceStore.supported
      ? AppleTvEnhanceStore()
      : null;

  /// This player's own licence, whatever server it is signed in to.
  final PlayerLicence player = PlayerLicence(store: SecurePlayerLicenceStore());

  /// The steps this player gives itself where no Lambent Server has a plan for
  /// it (ENTITLEMENTS.md section 8.3); null when there is a server to decide, or
  /// no licence. The device then runs what it can of them. Asking is playing,
  /// so it starts this player's trial.
  ({int lines, bool lift})? get localSteps {
    final purchases = current;
    if (purchases == null || purchases.isLambentServer) return null;
    if (!player.licensed) return null;
    player.startTrial();
    return (lines: 2160, lift: true);
  }

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
      player: player,
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

  /// Reads the signed-in server's licence again, when the app comes back to
  /// the front or the person opens Lambent's settings to look.
  Future<void> freshen() async =>
      current?.freshen(maxAge: const Duration(seconds: 5));

  /// Before a play starts ([EnhancePurchases.freshenForPlay]).
  Future<void> freshenForPlay() async => current?.freshenForPlay();

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
