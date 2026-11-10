import 'package:flutter/foundation.dart' show ValueNotifier;

/// The web has no remote access: see remote_access_native.dart.
class RemoteAccess {
  RemoteAccess._();

  static final RemoteAccess instance = RemoteAccess._();

  bool get available => false;

  void Function()? onRouteChanged;

  bool isAway(String baseUrl) => false;

  bool isTunnel(String address) => false;

  String? tunnelPath(String baseUrl) => null;

  String? tunnelAddress(String tunnelId) => null;

  Future<void> restore() async {}

  static bool isPairingLink(String text) => false;

  static final ValueNotifier<String?> pendingLink = ValueNotifier(null);

  Future<String> pairWithLink(String text, {required String name, required String kind}) =>
      throw const RemoteAccessException('This build has no remote access.');

  Future<String> join(String tunnelId, String home, {required String name, required String kind}) =>
      throw const RemoteAccessException('This build has no remote access.');

  Future<void> refreshHomes() async {}

  Future<void> reviveListeners() async {}
}

class RemoteAccessException implements Exception {
  const RemoteAccessException(this.message);

  final String message;

  @override
  String toString() => message;
}
