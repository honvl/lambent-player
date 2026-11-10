import 'dart:async';
import 'dart:convert';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:server_core/server_core.dart';

/// What the signed-in Lambent Server says it can do: `GET /v1/hello`'s
/// `features` (`enhanced_fi`: its PC makes in-between frames). Asked once a
/// server, and again after a while, since a PC's enhancer can come and go.
class LambentServerFeatures {
  LambentServerFeatures._();
  static final instance = LambentServerFeatures._();

  static const _maxAge = Duration(minutes: 5);

  String? _forServer;
  DateTime? _at;
  Set<String> _features = const {};
  Future<Set<String>>? _asking;

  /// The last answer for the signed-in server; empty before it has answered,
  /// and for a server that isn't Lambent's.
  Set<String> get known {
    final base = _baseUrl;
    return base != null && base == _forServer ? _features : const {};
  }

  /// The server's PC interpolates (`enhanced_fi`).
  bool get interpolates => known.contains('enhanced_fi');

  static String? get _baseUrl {
    if (!GetIt.instance.isRegistered<MediaServerClient>()) return null;
    // A client with no address to give (a stand-in) has no features either.
    try {
      final base = GetIt.instance<MediaServerClient>().baseUrl;
      return base.isEmpty ? null : base;
    } catch (_) {
      return null;
    }
  }

  /// The features, asking the server when the last answer is for another
  /// server or old. Never throws: a server that doesn't answer has none.
  Future<Set<String>> refresh() {
    final base = _baseUrl;
    if (base == null) return Future.value(const {});
    final fresh = _at != null && DateTime.now().difference(_at!) < _maxAge;
    if (base == _forServer && fresh) return Future.value(_features);
    return _asking ??= _ask(base).whenComplete(() => _asking = null);
  }

  Future<Set<String>> _ask(String base) async {
    final client = GetIt.instance<MediaServerClient>();
    final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    var features = const <String>{};
    try {
      final response = await http
          .get(
            Uri.parse('$root/v1/hello'),
            headers: {
              'Accept': 'application/json',
              if (client.accessToken case final token? when token.isNotEmpty)
                'X-Emby-Token': token,
            },
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body is Map && body['features'] is List) {
          features = (body['features'] as List).whereType<String>().toSet();
        }
      }
    } catch (_) {
      // Not Lambent Server, or not reachable now: nothing to offer.
    }
    if (_baseUrl == base) {
      _forServer = base;
      _at = DateTime.now();
      _features = features;
    }
    return features;
  }
}
