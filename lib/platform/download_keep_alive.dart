import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../data/services/download_service.dart';
import '../playback/headless_session_bootstrap.dart';
import '../remote/remote_access.dart';
import '../util/platform_detection.dart';

/// The share of a batch of downloads that is done, from 0 to 1. A title that
/// leaves the running list counts as done, so a finished one doesn't pull the
/// figure back down; only adding a title does. The batch ends when none runs.
@visibleForTesting
class DownloadBatchProgress {
  final _titles = <String, double>{};

  double update(Map<String, double> running) {
    if (running.isEmpty) {
      _titles.clear();
      return 0;
    }
    _titles.updateAll((_, _) => 1);
    running.forEach((id, progress) => _titles[id] = progress.clamp(0.0, 1.0));
    return _titles.values.reduce((a, b) => a + b) / _titles.length;
  }
}

/// Tells iOS's `DownloadKeepAlive` when a download goes through the Lambent
/// tunnel, so it can keep the app running: the tunnel lives in the app, and a
/// frozen app stops the system's background downloader reaching the PC.
class DownloadKeepAlive {
  DownloadKeepAlive._();

  static final instance = DownloadKeepAlive._();

  static const _channel = MethodChannel('org.moonfin/download_keep_alive');

  /// How long a cold launch gives the download service to adopt its transfers.
  static const _recoveryGrace = Duration(seconds: 5);

  final _batch = DownloadBatchProgress();
  DownloadService? _service;
  bool? _lastActive;
  int? _lastThousandths;

  /// Answers the native side's `wake`, sent when a scheduled task runs the app.
  void bind() {
    if (kIsWeb || !PlatformDetection.isIOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'wake') throw MissingPluginException();
      final getIt = GetIt.instance;
      if (!getIt.isRegistered<DownloadService>() &&
          getIt.isRegistered<HeadlessSessionBootstrap>()) {
        await getIt<HeadlessSessionBootstrap>().ensureSession(
          ignoreDisabledLoginBehavior: true,
        );
        await Future<void>.delayed(_recoveryGrace);
      }
      _changed();
    });
  }

  /// Follows [service], the active server's downloads.
  void attach(DownloadService service, String baseUrl) {
    if (kIsWeb || !PlatformDetection.isIOS) return;
    _service?.removeListener(_changed);
    _service = RemoteAccess.instance.isTunnel(baseUrl) ? service : null;
    _service?.addListener(_changed);
    _changed();
  }

  void _changed() {
    final running = <String, double>{
      for (final entry
          in _service?.activeDownloads.entries ??
              const <MapEntry<String, DownloadProgress>>[])
        if (entry.value.isInFlight) entry.key: entry.value.progress,
    };
    final active = running.isNotEmpty;
    final thousandths = (_batch.update(running) * 1000).round();
    if (active == _lastActive && thousandths == _lastThousandths) return;
    _lastActive = active;
    _lastThousandths = thousandths;
    unawaited(
      _channel
          .invokeMethod<void>('update', {
            'active': active,
            'fraction': thousandths / 1000,
          })
          .catchError((Object _) {}),
    );
  }
}
