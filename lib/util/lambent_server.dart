import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../auth/models/server.dart';
import '../remote/remote_access.dart';
import 'platform_detection.dart';

/// Lambent Server's Jellyfin server ids start with "lamb" in hex (Lambent's
/// `jellyfin::dto::server_id`), so a title says where it came from without
/// asking the server.
const _lambentServerIdPrefix = '6c616d62';

/// Whether [serverId] (an item's `ServerId`) is a Lambent Server's.
bool isLambentServerId(String? serverId) =>
    serverId != null &&
    serverId.toLowerCase().startsWith(_lambentServerIdPrefix);

/// Whether to offer SyncPlay on the active server. True outside a full app
/// session, where nothing has registered [ActiveServerKind].
bool syncPlayOffered() {
  final getIt = GetIt.instance;
  if (!getIt.isRegistered<ActiveServerKind>()) return true;
  return getIt<ActiveServerKind>().hasSyncPlay;
}

/// Caches what the active server said it is. A saved server's own id is the
/// app's, so only the server can say. Lambent Server answers as Jellyfin but has
/// no SyncPlay, and SyncPlay stays hidden until the answer lands, so it never
/// flashes up there.
class ActiveServerKind extends ChangeNotifier {
  int _generation = 0;
  bool? _isLambent;

  bool get hasSyncPlay => _isLambent == false;

  Future<void> refresh(MediaServerClient client) async {
    final generation = ++_generation;
    _isLambent = null;
    bool? isLambent = false;
    if (client.serverType == ServerType.jellyfin) {
      try {
        final info = await client.systemApi.getPublicSystemInfo();
        isLambent = isLambentServerId(info['Id'] as String?);
      } catch (_) {
        isLambent = null;
      }
    }
    // A server switch mid-probe means this answer belongs to the old server.
    if (generation != _generation) return;
    _isLambent = isLambent;
    notifyListeners();
  }
}

/// The address to show for [server]. A joined PC's saved one is its tunnel's loopback port, and it works at home and away.
String serverAddressLabel(Server server) =>
    RemoteAccess.instance.isTunnel(server.address)
    ? 'Home and away'
    : server.displayAddress ?? server.address;

/// How this device introduces itself to a PC it joins.
/// What the server's window calls this device: its own name, such as "NVIDIA SHIELD Android TV", so two of them can be told apart.
String get joiningName {
  final getIt = GetIt.instance;
  if (getIt.isRegistered<DeviceInfo>()) {
    final name = getIt<DeviceInfo>().name.trim();
    if (name.isNotEmpty) return name;
  }
  return PlatformDetection.isTV ? 'TV' : 'Phone or tablet';
}

/// An iPhone's or iPad's name. Without a special entitlement iOS 16 and later only say "iPhone", so the model is what tells one from another.
String appleMobileDeviceName({required String name, required String modelName, required String model}) {
  final own = name.trim();
  final marketing = modelName.trim();
  final generic = own.isEmpty || own == model.trim() || own == 'iPhone' || own == 'iPad';
  if (!generic) return own;
  if (marketing.isNotEmpty) return marketing;
  return own.isEmpty ? 'iPhone' : own;
}

/// A browser's name for the server, from its user agent: "Chrome on Mac".
String browserDeviceName(String userAgent) {
  final browser = userAgent.contains('Edg/')
      ? 'Edge'
      : userAgent.contains('Firefox/')
          ? 'Firefox'
          : userAgent.contains('Chrome/') || userAgent.contains('CriOS/')
              ? 'Chrome'
              : userAgent.contains('Safari/')
                  ? 'Safari'
                  : 'A browser';
  final system = userAgent.contains('Android')
      ? 'Android'
      : userAgent.contains('iPhone')
          ? 'iPhone'
          : userAgent.contains('iPad')
              ? 'iPad'
              : userAgent.contains('Windows')
                  ? 'Windows'
                  : userAgent.contains('Mac OS')
                      ? 'Mac'
                      : userAgent.contains('CrOS')
                          ? 'Chromebook'
                          : userAgent.contains('Linux')
                              ? 'Linux'
                              : '';
  return system.isEmpty ? browser : '$browser on $system';
}

String get joiningKind => PlatformDetection.isTV ? 'tv' : 'handheld';
