import 'package:server_core/server_core.dart';

class DiscoveredServer {
  final String id;
  final String name;
  final String address;
  final ServerType serverType;

  /// A Lambent Server's tunnel id, when its Bonjour record carries one.
  final String? irohId;

  const DiscoveredServer({
    required this.id,
    required this.name,
    required this.address,
    required this.serverType,
    this.irohId,
  });
}