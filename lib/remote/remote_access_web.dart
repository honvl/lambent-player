import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:web/web.dart' as web;

@JS('LambentDoor')
external _Door? get _door;

extension type _Door(JSObject _) implements JSObject {
  external bool available();
  external JSPromise<JSAny?> start();
  external JSPromise<JSAny?> pair(String id, String token, String name, String kind);
  external JSPromise<JSString> nearby();
  external JSPromise<JSAny?> join(String id, String name, String kind);
  external String route(String id);
}

/// The web app's way to its PC (web/lambent/door.js). A paired PC's address is `t/<tunnel id>` under this page, and a service worker carries what's sent
/// there over a WebRTC connection, so the rest of the app treats it like any other server. The same shape as remote_access_native.dart.
class RemoteAccess {
  RemoteAccess._();

  static final RemoteAccess instance = RemoteAccess._();

  static const _pathPart = '/t/';

  bool get available => _door?.available() ?? false;

  void Function()? onRouteChanged;

  static Uri get _page => Uri.parse(web.document.baseURI);

  static String? _idOf(String address) {
    final path = Uri.tryParse(address)?.path ?? '';
    final at = path.indexOf(_pathPart);
    if (at < 0) return null;
    final id = path.substring(at + _pathPart.length).split('/').first;
    return id.isEmpty ? null : id;
  }

  /// `home` or `direct`, for the stream information panel.
  String? tunnelPath(String baseUrl) {
    final id = _idOf(baseUrl);
    return id == null ? null : _door?.route(id);
  }

  /// A browser that isn't on the PC's network: the speed test and the ladder apply.
  bool isAway(String baseUrl) {
    final id = _idOf(baseUrl);
    return id != null && _door?.route(id) == 'direct';
  }

  bool isTunnel(String address) => _idOf(address) != null;

  String? tunnelAddress(String tunnelId) =>
      _page.resolve('t/$tunnelId').toString();

  /// Starts the service worker, before anything talks to a server.
  Future<void> restore() async {
    if (!available) return;
    try {
      await _door!.start().toDart;
    } catch (_) {}
  }

  static bool isPairingLink(String text) => text.trim().startsWith('lambent://pair');

  static final ValueNotifier<String?> pendingLink = ValueNotifier(null);

  /// Spends a link from the server's window, and returns the server's address.
  Future<String> pairWithLink(String text, {required String name, required String kind}) async {
    if (!available) throw const RemoteAccessException('This browser can\'t connect to a PC.');
    final uri = Uri.tryParse(text.trim());
    final id = uri?.queryParameters['id'];
    final token = uri?.queryParameters['token'];
    if (id == null || token == null) throw const RemoteAccessException('This pairing link is not complete.');
    try {
      await _door!.pair(id, token, name, kind).toDart;
    } catch (error) {
      throw RemoteAccessException(_messageOf(error));
    }
    return tunnelAddress(id)!;
  }

  static String _messageOf(Object error) {
    final text = error.toString();
    return text.isEmpty ? 'The PC could not be reached.' : text;
  }

  /// The PCs this browser can reach on its own network, by tunnel id and name.
  Future<List<({String id, String name})>> nearby() async {
    if (!available) return const [];
    try {
      final text = (await _door!.nearby().toDart).toDart;
      return [
        for (final pc in jsonDecode(text) as List)
          (id: pc['id'] as String, name: pc['name'] as String),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Joins a PC found by [nearby]. It lets this browser in only over the local network, so there's no address to pass on.
  Future<String> join(String tunnelId, String home, {required String name, required String kind}) async {
    if (!available) throw const RemoteAccessException('This browser can\'t connect to a PC.');
    try {
      await _door!.join(tunnelId, name, kind).toDart;
    } catch (error) {
      throw RemoteAccessException(_messageOf(error));
    }
    return tunnelAddress(tunnelId)!;
  }

  Future<void> refreshHomes() async {}

  Future<void> reviveListeners() async {}
}

class RemoteAccessException implements Exception {
  const RemoteAccessException(this.message);

  final String message;

  @override
  String toString() => message;
}
