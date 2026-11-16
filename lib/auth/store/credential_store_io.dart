import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_store_base.dart';
import '../../util/mac_keychain.dart';

/// Every call answers rather than throwing. A platform with no plugin
/// registered raises MissingPluginException, which is not a PlatformException,
/// and letting that escape takes sign in down with it even though the token
/// the session needs is already in hand. Losing the stored copy costs a sign
/// in on the next launch and nothing more.
class CredentialStoreImpl implements CredentialStore {
  // macOS: lambentMacKeychain picks the keychain. The data protection one
  // refuses every write from a build without a keychain access group (the
  // Developer ID download), so that build keeps the file based keychain; the
  // App Store build has one and never sees a login password prompt.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    mOptions: lambentMacKeychain,
  );
  bool _unavailable = false;

  @override
  bool get secureStorageUnavailable => _unavailable;

  @override
  bool consumeSecureStorageUnavailable() {
    final v = _unavailable;
    _unavailable = false;
    return v;
  }

  void _markUnavailable() => _unavailable = true;

  @override
  Future<void> saveToken(String serverId, String token) async {
    try {
      await _storage.write(
        key: '${CredentialStore.tokenKeyPrefix}$serverId',
        value: token,
      );
    } on Exception catch (_) {
      _markUnavailable();
    }
  }

  @override
  Future<String?> getToken(String serverId) async {
    try {
      return await _storage.read(
        key: '${CredentialStore.tokenKeyPrefix}$serverId',
      );
    } on Exception catch (_) {
      _markUnavailable();
      return null;
    }
  }

  @override
  Future<void> deleteToken(String serverId) async {
    try {
      await _storage.delete(
        key: '${CredentialStore.tokenKeyPrefix}$serverId',
      );
    } on Exception catch (_) {
      _markUnavailable();
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.deleteAll();
    } on Exception catch (_) {
      _markUnavailable();
    }
  }
}

CredentialStore createCredentialStore() => CredentialStoreImpl();
