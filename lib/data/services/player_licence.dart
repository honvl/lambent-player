import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'lambent_licence.dart';

/// Where this player keeps its key, leases and trial.
abstract class PlayerLicenceStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// The Keychain or Android Keystore. Every call answers rather than throwing:
/// a player that can't keep its key still plays, just without a licence.
class SecurePlayerLicenceStore implements PlayerLicenceStore {
  // macOS: the file based keychain, as CredentialStoreImpl says why.
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: 'lambent_player_$key');
    } on Exception catch (e) {
      debugPrint('PlayerLicence: read failed: $e');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: 'lambent_player_$key', value: value);
    } on Exception catch (e) {
      debugPrint('PlayerLicence: write failed: $e');
    }
  }
}

/// A lease (ENTITLEMENTS.md section 3), read but not yet trusted.
@immutable
class PlayerLease {
  const PlayerLease._(
    this.compact,
    this.payload,
    this.signature,
    this.household,
    this.issuedMs,
    this.expiresMs,
    this.entitlements,
  );

  final String compact;
  final Uint8List payload;
  final Uint8List signature;
  final String household;
  final int issuedMs;
  final int expiresMs;
  final List<({String name, int? untilMs, String source})> entitlements;

  /// Null when it isn't a lease this app can read.
  static PlayerLease? read(String compact) {
    final parts = compact.split('.');
    if (parts.length != 2) return null;
    try {
      final payload = _b64Decode(parts[0]);
      final json = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      if ((json['v'] as num) > 1) return null;
      return PlayerLease._(
        compact,
        payload,
        _b64Decode(parts[1]),
        json['household'] as String,
        (json['issued_ms'] as num).toInt(),
        (json['expires_ms'] as num).toInt(),
        [
          for (final e in json['entitlements'] as List)
            (
              name: e['name'] as String,
              untilMs: (e['until_ms'] as num?)?.toInt(),
              source: e['source'] as String,
            ),
        ],
      );
    } on Object {
      return null;
    }
  }

  /// When Enhance stops being current, if it is at [nowMs]: paid through or the
  /// lease's end, whichever comes first. A clock over a day before the lease
  /// was issued is wrong, and the lease isn't used.
  int? enhanceUntil(int nowMs) {
    if (nowMs < issuedMs - _clockSlackMs || nowMs >= expiresMs) return null;
    for (final e in entitlements) {
      if (e.name != 'enhance') continue;
      final until = e.untilMs;
      if (until == null) return expiresMs;
      if (nowMs < until) return min(until, expiresMs);
    }
    return null;
  }

  String? get enhanceSource {
    for (final e in entitlements) {
      if (e.name == 'enhance') return e.source;
    }
    return null;
  }

  static const _clockSlackMs = 24 * 3600 * 1000;
}

Uint8List _b64Decode(String text) =>
    base64Url.decode(base64Url.normalize(text));
String _b64Encode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// What the player can say about Enhance by itself, for a server that can't
/// (ENTITLEMENTS.md section 8): its own lease, the lease of a licensed Lambent
/// Server it met, or its trial.
class PlayerLicence extends ChangeNotifier {
  PlayerLicence({
    required PlayerLicenceStore store,
    http.Client? client,
    this.serviceUrl = 'https://getlambent.vercel.app',
    List<String>? serviceKeys,
    int Function()? nowMs,
    Duration timeout = const Duration(seconds: 15),
  }) : _store = store,
       _client = client ?? http.Client(),
       _serviceKeys =
           serviceKeys ??
           const [..._productionServiceKeys, if (kDebugMode) _testServiceKey],
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _timeout = timeout;

  /// The licence service's public keys, as Lambent Server's `SERVICE_KEYS`.
  static const List<String> _productionServiceKeys = [
    'TFNp0OkJ8WNrkTP1OsnKLlaaAN6M7PVioIOhOkSsgQc',
  ];

  /// Seed of 32 sevens (appendix A); debug builds only.
  static const _testServiceKey = '6kpsY-KcUgq-9VB7Ey7F-ZVHdq6-vnuSQh7qaRRG0iw';

  /// The server's rule (ENTITLEMENTS.md section 3.1): 7 days from first use.
  static const trialMs = 7 * 24 * 3600 * 1000;
  static const _presentationWindowMs = 5 * 60 * 1000;

  final PlayerLicenceStore _store;
  final http.Client _client;
  final List<String> _serviceKeys;
  final int Function() _now;
  final Duration _timeout;
  final String serviceUrl;
  final _ed25519 = Ed25519();

  SimpleKeyPair? _key;
  String? _id;
  PlayerLease? _own;
  PlayerLease? _received;
  int? _trialStartedMs;
  bool _everLeased = false;
  Future<void>? _starting;

  /// This player's id: its public key, base64url, as a household id is.
  String? get id => _id;

  /// Loads or makes the key, then asks the service for a lease.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    final seed = await _store.read('seed');
    final bytes = seed == null ? null : _tryDecode(seed);
    final Uint8List use;
    if (bytes != null && bytes.length == 32) {
      use = bytes;
    } else {
      final random = Random.secure();
      use = Uint8List.fromList(
        List.generate(32, (_) => random.nextInt(256)),
      );
      await _store.write('seed', _b64Encode(use));
    }
    _key = await _ed25519.newKeyPairFromSeed(use);
    _id = _b64Encode((await _key!.extractPublicKey()).bytes);

    _everLeased = await _store.read('ever_leased') == '1';
    _trialStartedMs = int.tryParse(await _store.read('trial_started_ms') ?? '');
    final own = await _store.read('lease');
    if (own != null) _own = await _trusted(own, holder: _id);
    final received = await _store.read('received');
    if (received != null) _received = await _trusted(received);
    notifyListeners();
    await refresh();
  }

  Uint8List? _tryDecode(String text) {
    try {
      return _b64Decode(text);
    } on FormatException {
      return null;
    }
  }

  /// [compact] when the licence service signed it, for [holder] if given.
  Future<PlayerLease?> _trusted(String compact, {String? holder}) async {
    final lease = PlayerLease.read(compact);
    if (lease == null) return null;
    if (holder != null && lease.household != holder) return null;
    for (final key in _serviceKeys) {
      final ok = await _ed25519.verify(
        lease.payload,
        signature: Signature(
          lease.signature,
          publicKey: SimplePublicKey(
            _b64Decode(key),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (ok) return lease;
    }
    return null;
  }

  /// `active`, `trial` or `none`.
  EnhanceState get state {
    final now = _now();
    if (_own?.enhanceUntil(now) != null ||
        _received?.enhanceUntil(now) != null) {
      return EnhanceState.active;
    }
    final started = _trialStartedMs;
    if (_key != null &&
        !_everLeased &&
        (started == null || now < started + trialMs)) {
      return EnhanceState.trial;
    }
    return EnhanceState.none;
  }

  /// Whether this player may do Enhance's steps itself.
  bool get licensed => state != EnhanceState.none;

  /// When the licence or the trial ends; null too for a trial not yet started.
  DateTime? get until {
    final now = _now();
    final ms =
        _own?.enhanceUntil(now) ??
        _received?.enhanceUntil(now) ??
        (state == EnhanceState.trial && _trialStartedMs != null
            ? _trialStartedMs! + trialMs
            : null);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// The first title this player upscales or lifts by itself starts the trial.
  void startTrial() {
    if (_key == null || _everLeased || _trialStartedMs != null) return;
    _trialStartedMs = _now();
    unawaited(_store.write('trial_started_ms', '$_trialStartedMs'));
    notifyListeners();
  }

  /// `paddle`, `app_store`, `play`, `server` (a licensed server's lease) or
  /// `trial`; null for none.
  String? get source {
    final now = _now();
    if (_own?.enhanceUntil(now) != null) return _own!.enhanceSource;
    if (_received?.enhanceUntil(now) != null) return 'server';
    return state == EnhanceState.trial ? 'trial' : null;
  }

  /// The checkout for this player, for builds that may link out. [start] told
  /// the service this is a player before anyone gets here.
  Uri? get buyUrl => _id == null ? null : Uri.parse('$serviceUrl/buy?household=$_id');

  /// A signed call (ENTITLEMENTS.md section 4.1): the body with keys sorted and
  /// no whitespace is what is signed, `sig` then takes its sorted place.
  Future<String> signedBody(
    String path,
    int tsMs, [
    Map<String, Object?> fields = const {},
  ]) async {
    final body = SplayTreeMap<String, Object?>.of({
      ...fields,
      'household': _id,
      'kind': 'player',
      'ts_ms': tsMs,
    });
    final text = jsonEncode(body);
    final signature = await _ed25519.sign(
      utf8.encode('$path\n$tsMs\n$text'),
      keyPair: _key!,
    );
    return jsonEncode(body..['sig'] = _b64Encode(signature.bytes));
  }

  /// Asks the service for this player's lease. Offline, the one it has stands.
  Future<void> refresh() async {
    if (_key == null) return;
    try {
      await _call('/api/v1/lease');
    } on LicenceException catch (e) {
      debugPrint('PlayerLicence: lease not refreshed: $e');
    }
  }

  /// A store purchase made with no Lambent Server to pass it on.
  Future<void> forward(StoreProof proof) async {
    await start();
    final fields = Map<String, Object?>.of(proof.toJson());
    final store = fields.remove('store');
    await _call(
      store == 'play' ? '/api/v1/store/play' : '/api/v1/store/apple',
      fields,
    );
  }

  /// Emails a sign-in link to [email].
  Future<void> requestSignIn(String email) async {
    await start();
    await _call('/api/v1/account/link', {'email': email});
  }

  /// Joins the account a sign-in code belongs to (section 8.1).
  Future<void> joinAccount(String code) async {
    await start();
    await _call('/api/v1/account/move', {'account_token': code.trim()});
  }

  Future<void> _call(
    String path, [
    Map<String, Object?> fields = const {},
  ]) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$serviceUrl$path'),
            headers: const {'Content-Type': 'application/json'},
            body: await signedBody(path, _now(), fields),
          )
          .timeout(_timeout);
    } on Exception catch (e) {
      throw LicenceException(0, message: '$e');
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      body = null;
    }
    final map = body is Map ? body : const {};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LicenceException(
        response.statusCode,
        code: map['error'] as String?,
        message: map['message'] as String?,
      );
    }
    if (map.containsKey('lease')) await _takeLease(map['lease'] as String?);
  }

  Future<void> _takeLease(String? compact) async {
    if (compact == null) {
      // Nothing is linked to this player any more.
      _own = null;
      await _store.write('lease', '');
      notifyListeners();
      return;
    }
    final lease = await _trusted(compact, holder: _id);
    if (lease == null) return;
    _own = lease;
    _everLeased = true;
    await _store.write('lease', compact);
    await _store.write('ever_leased', '1');
    notifyListeners();
  }

  /// This player's own lease, shown to [to], while it grants Enhance. A lease
  /// it was shown goes no further: only the key a lease names can show it.
  Future<LeasePresentation?> presentTo(String to) async {
    await start();
    final lease = _own;
    if (lease == null || lease.enhanceUntil(_now()) == null) return null;
    final ts = _now();
    final signature = await _ed25519.sign(
      utf8.encode(LeasePresentation.message(to, ts, lease.compact)),
      keyPair: _key!,
    );
    return LeasePresentation(
      lease: lease.compact,
      tsMs: ts,
      to: to,
      sig: _b64Encode(signature.bytes),
    );
  }

  /// Keeps a licensed server's lease it shows this player, when it checks out.
  /// The longest-lasting one stays. Returns whether it was good.
  Future<bool> accept(LeasePresentation presentation) async {
    await start();
    final now = _now();
    if (presentation.to != _id) return false;
    if ((now - presentation.tsMs).abs() > _presentationWindowMs) return false;
    final lease = await _trusted(presentation.lease);
    if (lease == null) return false;
    final until = lease.enhanceUntil(now);
    if (until == null) return false;
    final ok = await _verifyHolder(presentation, lease);
    if (!ok) return false;
    final held = _received?.enhanceUntil(now);
    if (held != null && held > until) return true;
    _received = lease;
    await _store.write('received', presentation.lease);
    notifyListeners();
    return true;
  }

  Future<bool> _verifyHolder(
    LeasePresentation presentation,
    PlayerLease lease,
  ) async {
    try {
      return await _ed25519.verify(
        utf8.encode(
          LeasePresentation.message(
            presentation.to,
            presentation.tsMs,
            presentation.lease,
          ),
        ),
        signature: Signature(
          _b64Decode(presentation.sig),
          publicKey: SimplePublicKey(
            _b64Decode(lease.household),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } on Object {
      return false;
    }
  }
}
