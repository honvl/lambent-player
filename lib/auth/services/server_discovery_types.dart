import 'package:server_core/server_core.dart';

import '../../util/lambent_server.dart';

class DiscoveredServer {
  final String id;
  final String name;
  final String address;
  final ServerType serverType;

  /// A Lambent Server's tunnel id, when its Bonjour record carries one.
  final String? irohId;

  /// A Lambent Server: one with an iroh tunnel (getlambent.app's nearby
  /// list on the web, a Bonjour record elsewhere), found through its own
  /// Bonjour record, or answering Jellyfin's discovery with a Lambent server
  /// id. It answers as Jellyfin, so [serverType] alone can't say.
  bool get isLambent =>
      irohId != null || id.startsWith('lambent:') || isLambentServerId(id);

  const DiscoveredServer({
    required this.id,
    required this.name,
    required this.address,
    required this.serverType,
    this.irohId,
  });
}
