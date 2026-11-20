import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../auth/repositories/session_repository.dart';
import '../../di/providers.dart';
import '../../l10n/app_localizations.dart';
import '../../util/platform_detection.dart';
import '../navigation/app_router.dart';
import '../navigation/destinations.dart';
import 'status_banner_pill.dart';

/// Floating glass pill shown while the device is offline or the server is
/// unreachable. Auto-dismisses after a few seconds and comes back whenever
/// the connection state changes again. On TV it stays non-focusable so it
/// never steals d-pad focus from the content underneath.
class OfflineBanner extends ConsumerStatefulWidget {
  const OfflineBanner({super.key});

  @override
  ConsumerState<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<OfflineBanner>
    with SingleTickerProviderStateMixin {
  static const _autoDismissDuration = Duration(seconds: 7);

  // Built in initState, not as field initializers: a banner that never becomes
  // visible would otherwise run them from dispose, and creating a ticker on a
  // deactivated element throws.
  late final AnimationController _entrance;
  late final CurvedAnimation _entranceCurve;

  bool _dismissed = false;
  bool _lastIsOnline = true;
  bool _lastServerReachable = true;
  Timer? _autoDismissTimer;

  /// Bumped on every visibility reset so the TV countdown bar restarts.
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _entranceCurve = CurvedAnimation(
      parent: _entrance,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _entranceCurve.dispose();
    _entrance.dispose();
    super.dispose();
  }

  static bool _signedIn() =>
      GetIt.instance.isRegistered<SessionRepository>() &&
      GetIt.instance<SessionRepository>().activeUserId != null;

  Future<void> _dismiss() async {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    await _entrance.reverse();
    if (mounted) setState(() => _dismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isOnline = ref.watch(isOnlineProvider);
    final serverReachable = ref.watch(activeServerReachableProvider);
    final isTv = PlatformDetection.useLeanbackUi;

    if (isOnline != _lastIsOnline || serverReachable != _lastServerReachable) {
      _lastIsOnline = isOnline;
      _lastServerReachable = serverReachable;
      _dismissed = false;
      _epoch++;
      _autoDismissTimer?.cancel();
      _autoDismissTimer = null;
      _entrance.value = 0;
    }

    if ((isOnline && serverReachable) || _dismissed) {
      return const SizedBox.shrink();
    }
    // Nobody signed in (a file from this device playing): there is no server
    // to have lost.
    if (isOnline && !_signedIn()) return const SizedBox.shrink();

    if (_entrance.status == AnimationStatus.dismissed) {
      _entrance.forward();
    }
    _autoDismissTimer ??= Timer(_autoDismissDuration, _dismiss);

    final isServerUnavailable = isOnline && !serverReachable;
    final tint = isServerUnavailable
        ? AppColorScheme.statusRequested
        : AppColorScheme.statusPending;
    final onSurface = AppColorScheme.onSurface;

    final pill = StatusBannerPill(
      icon: isServerUnavailable
          ? Icons.cloud_off_rounded
          : Icons.wifi_off_rounded,
      tint: tint,
      title: isServerUnavailable
          ? l10n.serverUnreachableBannerTitle
          : l10n.offlineBannerTitle,
      // TV can't download, so the downloads subtitle only shows on
      // platforms that can.
      subtitle: isTv
          ? null
          : isServerUnavailable
          ? l10n.serverUnreachableBannerSubtitle
          : l10n.offlineBannerSubtitle,
      trailing: [
        if (isTv)
          BannerCountdownBar(
            key: ValueKey(_epoch),
            duration: _autoDismissDuration,
            color: tint,
          )
        else ...[
          if (isServerUnavailable) ...[
            BannerActionCapsule(
              label: l10n.offlineSwitchServer,
              tint: tint,
              onTap: () => appRouter.go(Destinations.serverSelect),
            ),
            const SizedBox(width: 2),
          ],
          IconButton(
            onPressed: _dismiss,
            icon: Icon(
              Icons.close_rounded,
              size: 16,
              color: onSurface.withValues(alpha: 0.45),
            ),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ],
    );

    Widget banner = SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: pill,
        ),
      ),
    );

    if (!isTv) {
      banner = Dismissible(
        key: ValueKey(
          'offline_banner_${isServerUnavailable ? 'server' : 'network'}',
        ),
        direction: DismissDirection.horizontal,
        onDismissed: (_) {
          _autoDismissTimer?.cancel();
          _autoDismissTimer = null;
          setState(() => _dismissed = true);
        },
        child: banner,
      );
    }

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, -0.4),
        end: Offset.zero,
      ).animate(_entranceCurve),
      child: FadeTransition(opacity: _entranceCurve, child: banner),
    );
  }
}
