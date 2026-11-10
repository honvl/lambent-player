import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/services/server_discovery_service.dart';

/// Reaching a Lambent Server with no account: this device keeps its own key and joins the PC once, on its own at home or
/// with a pairing link from elsewhere. A joined PC is one server at a loopback address, and every connection from there
/// goes to the PC through an iroh tunnel, on the local network or not (Lambent's docs/REMOTE_ACCESS.md).
///
/// The tunnel is the MIT-licensed `lambent_tunnel` library, built by clients/lambent_tunnel/build_android.sh or build_ios.sh in the
/// Lambent repository and committed under jniLibs and ios/LambentTunnel. It isn't linked on Apple TV or the Mac yet, so there [available]
/// is false and nothing here does anything.
class RemoteAccess {
  RemoteAccess._();

  static final RemoteAccess instance = RemoteAccess._();

  static const _keyName = 'lambent_remote_device_key';
  static const _pairedName = 'lambent_remote_paired';
  static const _firstPort = 47810;
  static const _statusEvery = Duration(seconds: 3);
  static const _storage = FlutterSecureStorage();

  static final DynamicLibrary? _library = _open();

  static DynamicLibrary? _open() {
    try {
      final library = _load();
      // On iOS the app itself holds the library, or doesn't.
      if (library.providesSymbol('lambent_tunnel_new_key')) return library;
    } catch (_) {}
    return null;
  }

  static DynamicLibrary _load() => Platform.isAndroid ? DynamicLibrary.open('liblambent_tunnel.so') : DynamicLibrary.process();

  bool get available => _library != null;

  /// The ports of joined PCs whose connections run outside the local network just now.
  final _awayPorts = <int>{};

  /// Called when a joined PC's connections move between the local network and away: a measured link speed says nothing about the new one.
  void Function()? onRouteChanged;

  /// Which way [baseUrl]'s tunnel runs just now, or null when it isn't one.
  String? tunnelPath(String baseUrl) {
    if (!isTunnel(baseUrl)) return null;
    return switch (_api.status(Uri.parse(baseUrl).port)) {
      1 => 'Connecting',
      2 => 'Direct',
      3 => 'Relayed',
      4 => 'Local',
      _ => null,
    };
  }

  /// Whether [baseUrl] is a joined PC reached from outside the local network just now. Local plays stay as they are: only these measure the link.
  bool isAway(String baseUrl) => isTunnel(baseUrl) && _isAway(_api.status(Uri.parse(baseUrl).port));

  static bool _isAway(int status) => status == 2 || status == 3;

  /// Whether [address] is a joined PC's tunnel port, which works at home and away, and not a server on this device.
  bool isTunnel(String address) {
    final uri = Uri.tryParse(address);
    return uri != null && uri.host == '127.0.0.1' && _tunnelPorts.containsValue(uri.port);
  }

  /// The address a joined PC is saved at, or null when this device hasn't joined it.
  String? tunnelAddress(String tunnelId) {
    final port = _tunnelPorts[tunnelId];
    return port == null ? null : 'http://127.0.0.1:$port';
  }

  /// Each joined PC's tunnel id and port.
  final _tunnelPorts = <String, int>{};
  Timer? _statusTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  /// From the first tunnel on, tells [onRouteChanged] when a PC's connections move between local and away, and looks for the
  /// PCs again when the network changes.
  void _watch() {
    _statusTimer ??= Timer.periodic(_statusEvery, (_) => _pollStatus());
    _connectivity ??= Connectivity().onConnectivityChanged.listen((_) => refreshHomes());
  }

  void _pollStatus() {
    for (final port in _tunnelPorts.values) {
      final status = _api.status(port);
      // Connecting says nothing about the new route yet.
      if (status < 2) continue;
      final changed = _isAway(status) ? _awayPorts.add(port) : _awayPorts.remove(port);
      if (changed) onRouteChanged?.call();
    }
  }

  static _Api get _api => _Api(_library!);

  Future<String> _key() async {
    final saved = await _storage.read(key: _keyName);
    if (saved != null) return saved;
    final key = _api.newKey();
    await _storage.write(key: _keyName, value: key);
    // A key the store didn't keep would join a device that no longer exists after the next launch.
    final kept = await _storage.read(key: _keyName);
    if (kept != key) throw const RemoteAccessException('This device could not keep its key.');
    return key;
  }

  /// Tunnel id to what's known of that PC. A server record stores its address, so each PC keeps its port.
  Future<Map<String, _PairedPC>> _paired() async {
    final saved = await _storage.read(key: _pairedName);
    if (saved == null) return {};
    return (jsonDecode(saved) as Map<String, dynamic>).map((id, value) => MapEntry(id, _PairedPC.fromJson(value as Map<String, dynamic>)));
  }

  Future<void> _savePaired(Map<String, _PairedPC> paired) =>
      _storage.write(key: _pairedName, value: jsonEncode(paired.map((id, pc) => MapEntry(id, pc.toJson()))));

  Future<void> _changing = Future.value();

  /// Runs [change] after the ones before it, so two changes to the saved PCs don't overwrite each other.
  Future<T> _locked<T>(Future<T> Function() change) {
    final done = _changing.then((_) => change());
    _changing = done.then<void>((_) {}, onError: (_) {});
    return done;
  }

  bool _refreshing = false;

  /// Points each joined PC at the address Bonjour finds it at now, which DHCP may have changed. With nothing found it
  /// leaves what is stored, and it never holds up launch.
  Future<void> refreshHomes() async {
    if (!available || _tunnelPorts.isEmpty || _refreshing) return;
    _refreshing = true;
    try {
      final found = await ServerDiscoveryService().findLambentServers();
      await _locked(() async {
        final paired = await _paired();
        var changed = false;
        for (final server in found) {
          final id = server.irohId;
          final pc = id == null ? null : paired[id];
          final uri = Uri.tryParse(server.address);
          if (id == null || pc == null || uri == null) continue;
          final home = '${uri.host}:${uri.port}';
          _api.setHome(pc.port, home);
          if (pc.home != home) {
            paired[id] = _PairedPC(port: pc.port, home: home);
            changed = true;
          }
        }
        if (changed) await _savePaired(paired);
      });
    } catch (_) {
    } finally {
      _refreshing = false;
    }
  }

  /// Starts the tunnels of the PCs joined earlier. Call once at launch, before anything talks to a server.
  Future<void> restore() async {
    if (!available) return;
    try {
      final paired = await _paired();
      if (paired.isEmpty) return;
      final key = await _key();
      paired.forEach((id, pc) {
        _api.startOn(key, id, pc.port);
        _tunnelPorts[id] = pc.port;
        _api.setHome(pc.port, pc.home);
      });
      _watch();
      unawaited(refreshHomes());
    } catch (_) {}
  }

  /// iOS closes this app's listening sockets when it suspends it, and then every request is refused however well the PC answers. A dead
  /// listener goes back on the same port, which the server records already hold; a live one is left alone, with whatever is playing
  /// through it. Call on the way back to the foreground.
  Future<void> reviveListeners() async {
    if (!available || _tunnelPorts.isEmpty) return;
    await _locked(() async {
      final dead = <String, int>{};
      for (final MapEntry(key: id, value: port) in _tunnelPorts.entries) {
        if (!await _isListening(port)) dead[id] = port;
      }
      if (dead.isEmpty) return;
      try {
        final paired = await _paired();
        final key = await _key();
        // All of them before any comes back: the shared endpoint, as dead as they are, closes only once no tunnel is left.
        await Future.wait(dead.values.map(_stopped));
        dead.forEach((id, port) {
          if (_api.startOn(key, id, port) != 0) _api.setHome(port, paired[id]?.home);
        });
      } catch (_) {}
    });
  }

  /// Closing the endpoint takes a moment, so not on this isolate.
  static Future<void> _stopped(int port) => Isolate.run(() => _Api(_load()).stop(port));

  /// False only when nothing answers on [port]. A connection that just took long says nothing about the listener.
  static Future<bool> _isListening(int port) async {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
      socket.destroy();
      return true;
    } on SocketException catch (error) {
      return error.osError == null;
    }
  }

  /// The address to add as a server for this PC.
  Future<String> _serveThrough(String tunnelId, {String? home}) => _locked(() async {
        final paired = await _paired();
        final port = paired[tunnelId]?.port ?? _firstPort + paired.length;
        final key = await _key();
        if (_api.startOn(key, tunnelId, port) == 0 && _api.status(port) == 0) {
          throw const RemoteAccessException('The tunnel could not start.');
        }
        final where = home ?? paired[tunnelId]?.home;
        paired[tunnelId] = _PairedPC(port: port, home: where);
        await _savePaired(paired);
        _tunnelPorts[tunnelId] = port;
        _api.setHome(port, where);
        _watch();
        return 'http://127.0.0.1:$port';
      });

  static bool isPairingLink(String text) => text.trim().startsWith('lambent://pair');

  /// A pairing link that opened the app (a scanned QR code), until the server screen picks it up.
  static final ValueNotifier<String?> pendingLink = ValueNotifier(null);

  /// Spends a one-time link from the PC. Returns the server address to add.
  Future<String> pairWithLink(String text, {required String name, required String kind}) async {
    if (!available) throw const RemoteAccessException('This build has no remote access.');
    final link = Uri.tryParse(text.trim());
    final tunnelId = link?.queryParameters['id'];
    final token = link?.queryParameters['token'];
    if (tunnelId == null || token == null) {
      throw const RemoteAccessException("That isn't a pairing link.");
    }
    final key = await _key();
    // Blocks until the PC answers, so not on this isolate.
    final problem = await Isolate.run(() => _Api(_load()).redeem(key, tunnelId, token, name, kind));
    if (problem != null) throw RemoteAccessException(problem);
    return _serveThrough(tunnelId);
  }

  /// Joins the PC with tunnel id [tunnelId] that Bonjour found at [home] (host:port), with no approval: the PC lets in
  /// whatever reaches it on the local network. Returns the server address to add.
  Future<String> join(String tunnelId, String home, {required String name, required String kind}) async {
    if (!available) throw const RemoteAccessException('This build has no remote access.');
    final key = await _key();
    final address = await _ipAddress(home);
    // Blocks until the PC answers, so not on this isolate.
    final problem = await Isolate.run(() => _Api(_load()).join(key, tunnelId, address, name, kind));
    if (problem != null) throw RemoteAccessException(problem);
    return _serveThrough(tunnelId, home: address);
  }

  /// [home] (host:port) with the host as an IPv4 address, which is what the library dials.
  static Future<String> _ipAddress(String home) async {
    final colon = home.lastIndexOf(':');
    final host = home.substring(0, colon);
    if (InternetAddress.tryParse(host) != null) return home;
    final found = await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
    return '${found.first.address}${home.substring(colon)}';
  }
}

class _PairedPC {
  const _PairedPC({required this.port, this.home});

  factory _PairedPC.fromJson(Map<String, dynamic> json) {
    final home = json['home'] as String?;
    // The first versions stored the address as a URL.
    final uri = home == null || !home.contains('://') ? null : Uri.tryParse(home);
    return _PairedPC(port: json['port'] as int, home: uri == null ? home : '${uri.host}:${uri.hasPort ? uri.port : 80}');
  }

  final int port;

  /// Where the PC was last seen on the local network (host:port). Null for a PC joined by link from elsewhere.
  final String? home;

  Map<String, dynamic> toJson() => {'port': port, 'home': home};
}

class RemoteAccessException implements Exception {
  const RemoteAccessException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The C interface of `lambent_tunnel` (include/LambentTunnel/lambent_tunnel.h).
class _Api {
  _Api(DynamicLibrary library)
      : _newKey = library.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('lambent_tunnel_new_key'),
        _startOn = library.lookupFunction<Uint16 Function(Pointer<Utf8>, Pointer<Utf8>, Uint16), int Function(Pointer<Utf8>, Pointer<Utf8>, int)>(
            'lambent_tunnel_start_on'),
        _stop = library.lookupFunction<Void Function(Uint16), void Function(int)>('lambent_tunnel_stop'),
        _setHome = library.lookupFunction<Int32 Function(Uint16, Pointer<Utf8>), int Function(int, Pointer<Utf8>)>('lambent_tunnel_set_home'),
        _status = library.lookupFunction<Int32 Function(Uint16), int Function(int)>('lambent_tunnel_status'),
        _redeem = library.lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Size),
            int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int)>('lambent_tunnel_redeem'),
        _join = library.lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Size),
            int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int)>('lambent_tunnel_join');

  final void Function(Pointer<Utf8>) _newKey;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, int) _startOn;
  final void Function(int) _stop;
  final int Function(int, Pointer<Utf8>) _setHome;
  final int Function(int) _status;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int) _redeem;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int) _join;

  /// Runs [body] with [strings] as C strings and an out buffer, and frees them all.
  T _call<T>(List<String> strings, int capacity, T Function(List<Pointer<Utf8>> args, Pointer<Utf8> out) body) {
    final args = [for (final text in strings) text.toNativeUtf8()];
    final out = malloc<Uint8>(capacity).cast<Utf8>();
    try {
      return body(args, out);
    } finally {
      args.forEach(malloc.free);
      malloc.free(out);
    }
  }

  String newKey() => _call(const [], 65, (_, out) {
        _newKey(out);
        return out.toDartString();
      });

  int startOn(String key, String tunnelId, int port) => _call([key, tunnelId], 1, (args, _) => _startOn(args[0], args[1], port));

  void stop(int port) => _stop(port);

  void setHome(int port, String? home) {
    if (home == null) {
      _setHome(port, nullptr);
    } else {
      _call([home], 1, (args, _) => _setHome(port, args[0]));
    }
  }

  int status(int port) => _status(port);

  /// The reason it failed, or null.
  String? redeem(String key, String tunnelId, String token, String name, String kind) =>
      _call([key, tunnelId, token, name, kind], 512, (args, out) {
        return _redeem(args[0], args[1], args[2], args[3], args[4], out, 512) == 0 ? null : out.toDartString();
      });

  /// The reason it failed, or null.
  String? join(String key, String tunnelId, String home, String name, String kind) =>
      _call([key, tunnelId, home, name, kind], 512, (args, out) {
        return _join(args[0], args[1], args[2], args[3], args[4], out, 512) == 0 ? null : out.toDartString();
      });
}
