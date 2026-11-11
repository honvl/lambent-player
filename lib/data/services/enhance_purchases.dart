import 'dart:async';

import 'package:flutter/foundation.dart';

import 'lambent_licence.dart';
import 'player_licence.dart';

/// What a store purchase is doing, independent of the store plugin.
enum StoreTransactionStatus { pending, purchased, restored, error, canceled }

/// One purchase update from the store. [proof] is what Lambent Server needs to
/// verify it; [handle] is the plugin's own object, given back to [finish].
@immutable
class StoreTransaction {
  const StoreTransaction({
    required this.productId,
    required this.status,
    this.proof,
    this.needsFinish = false,
    this.handle,
    this.id,
  });

  final String productId;
  final StoreTransactionStatus status;
  final StoreProof? proof;

  /// The store holds this transaction open until [EnhanceStore.finish].
  final bool needsFinish;
  final Object? handle;

  /// The store's transaction id, when it gives one.
  final String? id;
}

/// One way to pay for Lambent Enhance: monthly, yearly or lifetime.
@immutable
class EnhanceProduct {
  const EnhanceProduct({
    required this.id,
    required this.title,
    required this.price,
    required this.yearly,
    this.lifetime = false,
    this.handle,
  });

  final String id;
  final String title;

  /// The store's own price text, in the buyer's currency.
  final String price;
  final bool yearly;
  final bool lifetime;
  final Object? handle;
}

/// The store side of an Enhance purchase: the App Store or Google Play behind
/// `in_app_purchase` in the app, a fake in tests.
abstract class EnhanceStore {
  /// Every purchase update, including ones the store re-delivers at launch
  /// because they were never finished.
  Stream<List<StoreTransaction>> get updates;

  Future<bool> isAvailable();
  Future<List<EnhanceProduct>> products();
  Future<void> buy(EnhanceProduct product);

  /// Asks the store to deliver the purchases it already knows about again.
  Future<void> restore();

  /// Tells the store the purchase has been delivered. Only after Lambent
  /// Server has confirmed it, so an unconfirmed purchase stays open and comes
  /// back on the next launch (ENTITLEMENTS.md section 7).
  Future<void> finish(StoreTransaction transaction);
}

/// Lambent Enhance on this screen: the server's licence, the store's products,
/// and every purchase passed to the server before the store is told it is
/// done.
class EnhancePurchases extends ChangeNotifier {
  EnhancePurchases({required this.client, this.store, this.player});

  final LambentLicenceClient client;

  /// This player's own licence (ENTITLEMENTS.md section 8): shown to a Lambent
  /// Server when they meet, and what a purchase goes to when there is none.
  final PlayerLicence? player;

  /// Null for builds that may not sell through a store (sideloaded Android,
  /// unsigned iOS and Apple TV): sideloaded Android shows the server's buy
  /// page instead.
  final EnhanceStore? store;

  StreamSubscription<List<StoreTransaction>>? _sub;

  LambentLicence? _licence;
  LambentLicence? get licence => _licence;

  /// False once the server answered that it has no licence route: not a
  /// Lambent Server, so there is nothing to show.
  bool _isLambent = true;
  bool get isLambentServer => _isLambent;

  List<EnhanceProduct> _products = const [];
  List<EnhanceProduct> get products => _products;

  bool _busy = false;

  /// A purchase is under way or being confirmed with the server.
  bool get busy => _busy;

  String? _message;

  /// A line for the person about the last purchase, or null.
  String? get message => _message;

  /// Purchases the server has not confirmed yet. Kept open in the store.
  final List<StoreTransaction> _unconfirmed = [];
  int get unconfirmedCount => _unconfirmed.length;

  bool get canBuyInApp => store != null && _products.isNotEmpty;

  /// Starts listening to the store and loads the licence and the products.
  /// The store re-delivers unfinished purchases on its own once listened to.
  Future<void> start() async {
    final store = this.store;
    if (store != null) {
      _sub ??= store.updates.listen(_onUpdates);
    }
    await refresh();
    await loadProducts();
  }

  Future<void>? _loadingProducts;

  /// Loads the store's products, unless they are loaded or loading. The
  /// settings screen calls it again in case the store had nothing at launch.
  Future<void> loadProducts() {
    final store = this.store;
    if (store == null || (!_isLambent && player == null) || _products.isNotEmpty) {
      return Future.value();
    }
    return _loadingProducts ??= () async {
      try {
        if (await store.isAvailable()) {
          _products = await store.products();
          notifyListeners();
        }
      } catch (e) {
        debugPrint('EnhancePurchases: products failed: $e');
      } finally {
        _loadingProducts = null;
      }
    }();
  }

  /// Asks the server for the licence again.
  Future<void> refresh() async {
    try {
      await player?.start();
      final licence = await client.fetch(player: player?.id);
      _isLambent = licence != null;
      _licence = licence;
      await _meet(licence);
    } on LicenceException catch (e) {
      debugPrint('EnhancePurchases: licence fetch failed: $e');
    }
    notifyListeners();
  }

  /// A licensed player and a Lambent Server show each other their leases, so
  /// that either one's purchase covers both (section 8.2).
  Future<void> _meet(LambentLicence? licence) async {
    final player = this.player;
    if (player == null || licence == null) return;
    final theirs = licence.present;
    if (theirs != null) await player.accept(theirs);
    final household = licence.household;
    if (household == null) return;
    final ours = await player.presentTo(household);
    if (ours == null) return;
    try {
      _licence = await client.present(ours) ?? licence;
    } on LicenceException catch (e) {
      debugPrint('EnhancePurchases: the server refused the lease: $e');
    }
  }

  Future<void> buy(EnhanceProduct product) async {
    final store = this.store;
    if (store == null) return;
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      await store.buy(product);
    } catch (e) {
      _busy = false;
      _message = "The store couldn't start the purchase.";
      notifyListeners();
    }
  }

  Future<void> restore() async {
    final store = this.store;
    if (store == null) return;
    _message = null;
    notifyListeners();
    await store.restore();
  }

  /// Sends every purchase the server has not confirmed yet again, for a
  /// launch after the server or the licence service was unreachable.
  Future<void> retryUnconfirmed() async {
    final pending = List.of(_unconfirmed);
    _unconfirmed.clear();
    await _onUpdates(pending);
  }

  Future<void> _onUpdates(List<StoreTransaction> updates) async {
    for (final t in updates) {
      switch (t.status) {
        case StoreTransactionStatus.pending:
          _busy = true;
          _message = 'Waiting for the store to finish the purchase.';
        case StoreTransactionStatus.purchased:
        case StoreTransactionStatus.restored:
          await _confirm(t);
        case StoreTransactionStatus.error:
          _busy = false;
          _message = "The purchase didn't go through.";
          await _finishQuietly(t);
        case StoreTransactionStatus.canceled:
          _busy = false;
          _message = null;
          await _finishQuietly(t);
      }
      notifyListeners();
    }
  }

  /// Forwards by transaction id, each completing with whether the server
  /// confirmed it. StoreKit 2 delivers a purchase twice, as the purchase's
  /// result and as a transaction update; the second copy waits for the first.
  final Map<String, Future<bool>> _forwards = {};

  Future<void> _confirm(StoreTransaction t) async {
    final proof = t.proof;
    if (proof == null) {
      // Nothing the server could check; leave it open for the next launch.
      _unconfirmed.add(t);
      _busy = false;
      return;
    }
    final id = t.id;
    final earlier = id == null ? null : _forwards[id];
    if (earlier != null) {
      if (await earlier) await _finishQuietly(t);
      return;
    }
    final confirmed = Completer<bool>();
    if (id != null) _forwards[id] = confirmed.future;
    _busy = true;
    notifyListeners();
    try {
      final player = this.player;
      if (_isLambent || player == null) {
        _licence = await client.forward(proof);
        _isLambent = true;
      } else {
        // No Lambent Server to pass it on: this player holds it.
        await player.forward(proof);
      }
      confirmed.complete(true);
      _unconfirmed.removeWhere((u) => identical(u.handle, t.handle));
      await _finishQuietly(t);
      _message = t.status == StoreTransactionStatus.purchased
          ? (_isLambent
                ? 'Lambent Enhance is on for your server.'
                : 'Lambent Enhance is on for this device.')
          : null;
    } on LicenceException catch (e) {
      confirmed.complete(false);
      // A later retry forwards it again.
      _forwards.remove(id);
      // Not finished: the store keeps it and hands it back on the next
      // launch, and retryUnconfirmed can try again before then.
      if (!_unconfirmed.any((u) => identical(u.handle, t.handle))) {
        _unconfirmed.add(t);
      }
      _message = e.transient
          ? "Your purchase is safe, but your Lambent Server couldn't confirm "
                "it yet. It will try again the next time Lambent opens."
          : 'Your Lambent Server refused the purchase'
                '${e.message == null ? '.' : ': ${e.message}'}';
    } finally {
      _busy = false;
    }
  }

  Future<void> _finishQuietly(StoreTransaction t) async {
    if (!t.needsFinish) return;
    try {
      await store?.finish(t);
    } catch (e) {
      debugPrint('EnhancePurchases: finish failed: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
