import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:server_core/server_core.dart';

import '../../data/services/log_service.dart';
import '../../util/platform_detection.dart';

import 'server_discovery_types.dart';

class ServerDiscoveryService {
  static const _discoveryPort = 7359;
  static const _jellyfinMessage = 'who is JellyfinServer?';
  static const _embyMessage = 'who is EmbyServer?';
  static const _plexDiscoveryPort = 32414;
  static const _plexMessage = 'M-SEARCH * HTTP/1.1\r\n\r\n';
  static const _listenDuration = Duration(milliseconds: 2500);
  static const _rebroadcastInterval = Duration(milliseconds: 800);

  /// Lambent Server advertises itself over Bonjour and does not answer
  /// Jellyfin's UDP discovery on 7359, so it is found here instead.
  static const _lambentService = '_vbridge._tcp.local';
  static const _multicastLock = MethodChannel('org.moonfin/multicast_lock');
  static const _bonjour = MethodChannel('org.moonfin/bonjour');

  Stream<DiscoveredServer> discoverLocalServers() async* {
    final controller = StreamController<DiscoveredServer>();
    final seen = <String>{};
    // A Plex server on a machine that also runs Lambent Server is the one
    // Lambent fronts; offering it too invites signing in past the enhancement.
    // Plex answers wait until the Bonjour lookup has had its chance.
    final lambentHosts = <String>{};
    final plexHeld = <DiscoveredServer>[];
    void emit(DiscoveredServer server) {
      if (!controller.isClosed && seen.add(server.id)) controller.add(server);
    }

    void releasePlex() {
      for (final plex in plexHeld) {
        final host = Uri.tryParse(plex.address)?.host;
        if (host == null || !lambentHosts.contains(host)) emit(plex);
      }
      plexHeld.clear();
    }
    RawDatagramSocket? socket;
    Timer? rebroadcastTimer;
    Timer? stopTimer;

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      final broadcastAddresses = await _getBroadcastAddresses();
      final jellyfinData = utf8.encode(_jellyfinMessage);
      final embyData = utf8.encode(_embyMessage);
      final plexData = utf8.encode(_plexMessage);

      void sendBroadcasts() {
        for (final addr in broadcastAddresses) {
          try {
            socket!.send(jellyfinData, addr, _discoveryPort);
            socket.send(embyData, addr, _discoveryPort);
            socket.send(plexData, addr, _plexDiscoveryPort);
          } catch (_) {}
        }
      }

      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram == null) return;
        final response = utf8.decode(datagram.data);
        final server = response.startsWith('HTTP/')
            ? parsePlexGdmResponse(response, datagram.address.address)
            : _parseResponse(response);
        if (server == null) return;
        if (server.serverType == ServerType.plex) {
          plexHeld.add(server);
        } else {
          emit(server);
        }
      });

      unawaited(
        _discoverLambent((server) {
          final host = Uri.tryParse(server.address)?.host;
          if (host != null) lambentHosts.add(host);
          emit(server);
        }),
      );

      sendBroadcasts();
      rebroadcastTimer = Timer.periodic(_rebroadcastInterval, (_) {
        sendBroadcasts();
      });
      stopTimer = Timer(_listenDuration, () {
        releasePlex();
        if (!controller.isClosed) controller.close();
      });

      yield* controller.stream;
    } catch (error) {
      // Swallowing this leaves an empty list that reads exactly like a
      // network with no servers on it.
      if (GetIt.instance.isRegistered<LogService>()) {
        GetIt.instance<LogService>().network(
          'Local server discovery failed',
          level: LogLevel.error,
          error: error,
        );
      }
      if (!controller.isClosed) await controller.close();
    } finally {
      rebroadcastTimer?.cancel();
      stopTimer?.cancel();
      socket?.close();
      if (!controller.isClosed) await controller.close();
    }
  }

  /// Browses Bonjour for Lambent Server, calling [found] for each one that
  /// resolves to an IPv4 address. Lambent Server answers as a Jellyfin server.
  Future<void> _discoverLambent(void Function(DiscoveredServer) found) async {
    // Apple TV and iOS only let the system's Bonjour browse (the app holds no
    // multicast entitlement), so the native side does it there.
    if (PlatformDetection.isAppleTV || PlatformDetection.isIOS) {
      return _discoverLambentNative(found);
    }
    final client = MDnsClient();
    try {
      // Wi-Fi drops multicast on Android unless the app holds a lock.
      if (Platform.isAndroid) {
        try {
          await _multicastLock.invokeMethod<bool>('acquire');
        } catch (_) {}
      }
      await client.start();
      final timeout = _listenDuration - const Duration(milliseconds: 300);
      await for (final ptr in client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_lambentService),
          )
          .timeout(timeout, onTimeout: (sink) => sink.close())) {
        final txt = <String, String>{};
        await for (final record in client.lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(ptr.domainName),
        )) {
          for (final line in record.text.split('\n')) {
            final i = line.indexOf('=');
            if (i > 0) txt[line.substring(0, i)] = line.substring(i + 1);
          }
        }
        await for (final srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
        )) {
          await for (final ip in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
          )) {
            final name = txt['name'] ??
                ptr.domainName.split('.').first;
            found(
              DiscoveredServer(
                id: 'lambent:${txt['id'] ?? ptr.domainName}',
                name: name,
                address: 'http://${ip.address.address}:${srv.port}',
                serverType: ServerType.jellyfin,
              ),
            );
            break;
          }
          break;
        }
      }
    } catch (error) {
      if (GetIt.instance.isRegistered<LogService>()) {
        GetIt.instance<LogService>().network(
          'Lambent Server Bonjour discovery failed',
          level: LogLevel.warning,
          error: error,
        );
      }
    } finally {
      client.stop();
      if (Platform.isAndroid) {
        try {
          await _multicastLock.invokeMethod<void>('release');
        } catch (_) {}
      }
    }
  }

  Future<void> _discoverLambentNative(
    void Function(DiscoveredServer) found,
  ) async {
    try {
      final results = await _bonjour.invokeListMethod<Map>('browse', {
        'type': '_vbridge._tcp',
        'timeoutMs':
            (_listenDuration - const Duration(milliseconds: 300)).inMilliseconds,
      });
      for (final result in results ?? const <Map>[]) {
        final txt = (result['txt'] as Map?)?.cast<String, String>() ?? const {};
        final name = result['name'] as String? ?? 'Lambent Server';
        found(
          DiscoveredServer(
            id: 'lambent:${txt['id'] ?? name}',
            name: txt['name'] ?? name,
            address: 'http://${result['host']}:${result['port']}',
            serverType: ServerType.jellyfin,
          ),
        );
      }
    } catch (error) {
      if (GetIt.instance.isRegistered<LogService>()) {
        GetIt.instance<LogService>().network(
          'Lambent Server Bonjour discovery failed',
          level: LogLevel.warning,
          error: error,
        );
      }
    }
  }

  DiscoveredServer? _parseResponse(String response) {
    try {
      final data = jsonDecode(response) as Map<String, dynamic>;
      final address = data['Address'] as String?;
      final id = data['Id']?.toString();
      if (address == null || id == null) return null;

      final name = data['Name'] as String? ?? id;

      final serverType = name.toLowerCase().contains('emby')
          ? ServerType.emby
          : ServerType.jellyfin;

      return DiscoveredServer(
        id: id,
        name: name,
        address: address,
        serverType: serverType,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<InternetAddress>> _getBroadcastAddresses() async {
    final addresses = <InternetAddress>[InternetAddress('255.255.255.255')];
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              final broadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
              final broadcastAddr = InternetAddress(broadcast);
              if (!addresses.any((a) => a.address == broadcastAddr.address)) {
                addresses.add(broadcastAddr);
              }
            }
          }
        }
      }
    } catch (_) {}
    return addresses;
  }
}

/// Plex answers GDM with HTTP style headers instead of JSON.
DiscoveredServer? parsePlexGdmResponse(String response, String host) {
  final headers = <String, String>{
    for (final line in response.split('\r\n'))
      if (line.indexOf(':') case final i when i > 0)
        line.substring(0, i).toLowerCase(): line.substring(i + 1).trim(),
  };
  final id = headers['resource-identifier'];
  if (id == null || headers['content-type'] != 'plex/media-server') {
    return null;
  }
  return DiscoveredServer(
    id: id,
    name: headers['name'] ?? id,
    address: 'http://$host:${headers['port'] ?? '32400'}',
    serverType: ServerType.plex,
  );
}
