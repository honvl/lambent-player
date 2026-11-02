import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Lambent Enhance on the signed-in server's household, as Lambent Server
/// reports it (ENTITLEMENTS.md section 7).
enum EnhanceState { active, trial, preview, none }

/// The body of Lambent Server's `GET /v1/licence`.
@immutable
class LambentLicence {
  const LambentLicence({
    required this.enhance,
    this.until,
    this.source,
    this.proOnHousehold = false,
    this.buyUrl,
  });

  factory LambentLicence.fromJson(Map<String, dynamic> json) {
    final enhance = json['enhance'];
    final e = enhance is Map ? enhance : const {};
    final untilMs = e['until_ms'];
    final buy = json['buy_url'];
    return LambentLicence(
      enhance: switch (e['state']) {
        'active' => EnhanceState.active,
        'trial' => EnhanceState.trial,
        'preview' => EnhanceState.preview,
        _ => EnhanceState.none,
      },
      until: untilMs is num
          ? DateTime.fromMillisecondsSinceEpoch(untilMs.toInt())
          : null,
      source: e['source'] as String?,
      proOnHousehold: json['pro_on_this_household'] == true,
      buyUrl: buy is String ? Uri.tryParse(buy) : null,
    );
  }

  final EnhanceState enhance;

  /// When the paid-through time or the trial ends; null for none or forever.
  final DateTime? until;

  /// `paddle`, `app_store` or `play`, when a purchase grants it.
  final String? source;
  final bool proOnHousehold;

  /// The server's own checkout page, for builds that may not sell in-app.
  final Uri? buyUrl;

  /// Whether the household has Enhance, bought or on trial.
  bool get enhanced =>
      enhance == EnhanceState.active || enhance == EnhanceState.trial;

  /// Whether the player may play a title enhanced full screen. Without
  /// Enhance or a trial it may only compare it with the original side by
  /// side.
  bool get mayPlayEnhanced => enhanced;

  /// The settings line: "Enhanced by your Lambent Server" or why not.
  String get headline => switch (enhance) {
    EnhanceState.active => 'Enhanced by your Lambent Server',
    EnhanceState.trial => 'Enhanced by your Lambent Server (trial)',
    EnhanceState.preview ||
    EnhanceState.none => "Your server doesn't have Lambent Enhance",
  };

  /// A second line with the date, when there is one to give.
  String? detail(String Function(DateTime) formatDate) {
    final until = this.until;
    return switch (enhance) {
      EnhanceState.active when until != null =>
        'Renews or ends ${formatDate(until)}',
      EnhanceState.trial when until != null =>
        'Trial ends ${formatDate(until)}',
      EnhanceState.preview || EnhanceState.none =>
        'Compare enhanced with the original, side by side, in the player',
      _ => null,
    };
  }
}

/// The proof a store hands over for one purchase, in the shape Lambent Server
/// forwards to the licence service.
@immutable
sealed class StoreProof {
  const StoreProof();
  Map<String, String> toJson();
}

/// An App Store transaction: StoreKit 2's signed transaction (JWS).
class AppStoreProof extends StoreProof {
  const AppStoreProof(this.transaction);
  final String transaction;

  @override
  Map<String, String> toJson() => {
    'store': 'app_store',
    'transaction': transaction,
  };
}

/// A Google Play purchase: the package, the subscription's product id and the
/// purchase token.
class PlayProof extends StoreProof {
  const PlayProof({
    required this.package,
    required this.product,
    required this.token,
  });
  final String package;
  final String product;
  final String token;

  @override
  Map<String, String> toJson() => {
    'store': 'play',
    'package': package,
    'product': product,
    'token': token,
  };
}

/// Lambent Server refused or could not pass on a purchase. [status] is the
/// HTTP status (502 when the licence service can't be reached), [code] the
/// server's `error` value when it sent one.
class LicenceException implements Exception {
  const LicenceException(this.status, {this.code, this.message});
  final int status;
  final String? code;
  final String? message;

  /// Worth trying again later: the server or the service was unreachable,
  /// not a verdict on the purchase.
  bool get transient => status == 0 || status == 502 || status >= 500;

  @override
  String toString() => 'LicenceException($status, $code, $message)';
}

/// Lambent Server's two licence routes on the signed-in server's address.
class LambentLicenceClient {
  LambentLicenceClient({
    required this.baseUrl,
    this.accessToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String? accessToken;
  final Duration timeout;
  final http.Client _client;

  Uri _uri(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$path');
  }

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (accessToken case final token? when token.isNotEmpty)
      'X-Emby-Token': token,
  };

  /// The server's licence, or null when the server has no such route (a
  /// Jellyfin or Emby server that is not Lambent).
  Future<LambentLicence?> fetch() async {
    final http.Response response;
    try {
      response = await _client
          .get(_uri('/v1/licence'), headers: _headers)
          .timeout(timeout);
    } on Exception catch (e) {
      throw LicenceException(0, message: '$e');
    }
    if (response.statusCode == 404) return null;
    return _licenceOrThrow(response);
  }

  /// Hands a store purchase to the server, which has the licence service
  /// verify it; answers with the household's licence afterwards.
  Future<LambentLicence> forward(StoreProof proof) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            _uri('/v1/licence/store'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode(proof.toJson()),
          )
          .timeout(timeout);
    } on Exception catch (e) {
      throw LicenceException(0, message: '$e');
    }
    return _licenceOrThrow(response);
  }

  LambentLicence _licenceOrThrow(http.Response response) {
    Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      body = null;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (body is Map<String, dynamic>) return LambentLicence.fromJson(body);
      throw LicenceException(response.statusCode, code: 'bad_body');
    }
    final error = body is Map ? body : const {};
    throw LicenceException(
      response.statusCode,
      code: error['error'] as String?,
      message: error['message'] as String?,
    );
  }

  void close() => _client.close();
}
