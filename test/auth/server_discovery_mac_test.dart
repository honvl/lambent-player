import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/auth/services/server_discovery_service_io.dart';
import 'package:server_core/server_core.dart';

/// The Mac app has no com.apple.security.network.server, so its sandbox refuses
/// any UDP socket of the app's own: discovery there must go through the
/// system's Bonjour and leave the broadcasts and Silo's mDNS browse alone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const bonjour = MethodChannel('org.moonfin/bonjour');

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(bonjour, null);
  });

  test('the Mac finds Lambent Server through Bonjour and opens no socket',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(bonjour, (call) async {
      calls.add(call);
      return [
        {
          'name': 'GOLDENCHOCOBO',
          'host': '192.168.1.50',
          'port': 8096,
          'txt': {'id': 'abc123', 'name': 'Living room PC', 'iroh': 'node1'},
        },
      ];
    });
    var siloBrowsed = false;

    final found = await ServerDiscoveryService(
      siloBrowser: () async {
        siloBrowsed = true;
        return const [];
      },
    ).discoverLocalServers().toList();

    expect(calls.single.method, 'browse');
    expect((calls.single.arguments as Map)['type'], '_vbridge._tcp');
    expect(siloBrowsed, isFalse);
    expect(found, hasLength(1));
    expect(found.single.id, 'lambent:abc123');
    expect(found.single.name, 'Living room PC');
    expect(found.single.address, 'http://192.168.1.50:8096');
    expect(found.single.serverType, ServerType.jellyfin);
    expect(found.single.irohId, 'node1');
  });

  test('an empty Bonjour browse still ends the list', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(bonjour, (call) async => const []);

    final found = await ServerDiscoveryService(
      siloBrowser: () async => const [],
    ).discoverLocalServers().toList();

    expect(found, isEmpty);
  });
}
