import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/auth/services/server_discovery_types.dart';
import 'package:server_core/server_core.dart';

DiscoveredServer _found(String id, {String? irohId}) => DiscoveredServer(
      id: id,
      name: 'PC',
      address: 'http://192.168.1.2:8096',
      serverType: ServerType.jellyfin,
      irohId: irohId,
    );

void main() {
  test('Lambent Servers are told from Jellyfin ones however they were found', () {
    expect(_found('lambent:abc').isLambent, isTrue, reason: 'Bonjour record');
    expect(_found('6c616d62deadbeef').isLambent, isTrue, reason: 'Jellyfin discovery');
    expect(_found('f00d', irohId: 'f00d').isLambent, isTrue, reason: "getlambent.app's nearby list");
    expect(_found('0123456789abcdef').isLambent, isFalse, reason: 'a Jellyfin server');
  });
}
