import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../../auth/repositories/server_repository.dart';
import '../../../auth/repositories/session_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../navigation/destinations.dart';
import '../../../util/lambent_brand.dart';

/// The panel covers Jellyfin, and Emby from 4.9, the oldest Emby it was
/// checked against.
bool adminServerSupported() {
  if (!LambentBrand.enableServerAdmin) return false;
  final getIt = GetIt.instance;
  if (!getIt.isRegistered<MediaServerClient>()) return false;
  if (getIt<MediaServerClient>().serverType == ServerType.jellyfin) return true;
  final serverId = getIt<SessionRepository>().activeServerId;
  final server = serverId == null
      ? null
      : getIt<ServerRepository>().getServer(serverId);
  return server != null && embyVersionSupported(server.version);
}

bool embyVersionSupported(String version) {
  final parts = version.split('.').map(int.tryParse).toList();
  final major = parts.firstOrNull ?? 0;
  final minor = parts.elementAtOrNull(1) ?? 0;
  return major > 4 || (major == 4 && minor >= 9);
}

/// The server the admin area is talking to, Jellyfin when there's no client.
ServerType adminServerType() => GetIt.instance.isRegistered<MediaServerClient>()
    ? GetIt.instance<MediaServerClient>().serverType
    : ServerType.jellyfin;

/// Tells the admin pages which server they're on. Without one, as in tests
/// that build a single page, they act as on Jellyfin.
class AdminServerScope extends InheritedWidget {
  const AdminServerScope({
    super.key,
    required this.serverType,
    required super.child,
  });

  final ServerType serverType;

  /// Doesn't subscribe, since the server can't change under a mounted area.
  /// That also makes it safe to call from initState.
  static ServerType of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AdminServerScope>()?.serverType ??
      ServerType.jellyfin;

  static bool isEmby(BuildContext context) => of(context) == ServerType.emby;

  @override
  bool updateShouldNotify(AdminServerScope oldWidget) =>
      oldWidget.serverType != serverType;
}

/// One page of the admin area, as the rail, page list and phone tabs show it.
class AdminPage {
  const AdminPage({
    required this.id,
    required this.route,
    required this.icon,
    required this.title,
    required this.description,
    this.iconAsset,
    this.servers,
  });

  final String id;
  final String route;
  final IconData icon;

  /// A tinted image in place of [icon] (Libraries uses the clapperboard).
  final String? iconAsset;
  final String Function(AppLocalizations l10n) title;
  final String Function(AppLocalizations l10n) description;

  /// The servers that have this page, every server when null.
  final Set<ServerType>? servers;

  bool availableOn(ServerType type) => servers?.contains(type) ?? true;

  Widget buildIcon(double size, Color color) => iconAsset == null
      ? Icon(icon, size: size, color: color)
      : Image.asset(iconAsset!, width: size, height: size, color: color);
}

class AdminGroup {
  const AdminGroup({
    required this.id,
    required this.icon,
    required this.title,
    required this.pages,
  });

  final String id;
  final IconData icon;
  final String Function(AppLocalizations l10n) title;
  final List<AdminPage> pages;

  List<AdminPage> pagesOn(ServerType type) => [
    for (final page in pages)
      if (page.availableOn(type)) page,
  ];
}

/// The admin area grouped by task rather than by server subsystem.
final List<AdminGroup> adminGroups = [
  AdminGroup(
    id: 'overview',
    icon: Icons.monitor_heart_outlined,
    title: (l) => l.adminGroupOverview,
    pages: [
      AdminPage(
        id: 'dashboard',
        route: Destinations.admin,
        icon: Icons.dashboard_outlined,
        title: (l) => l.adminDrawerDashboard,
        description: (l) => l.adminPageDescDashboard,
      ),
      AdminPage(
        id: 'analytics',
        route: Destinations.adminAnalytics,
        icon: Icons.insights,
        title: (l) => l.adminDrawerAnalytics,
        description: (l) => l.adminPageDescAnalytics,
      ),
      AdminPage(
        id: 'activity',
        route: Destinations.adminActivity,
        icon: Icons.history,
        title: (l) => l.adminDrawerActivity,
        description: (l) => l.adminPageDescActivity,
      ),
      AdminPage(
        id: 'scheduled-tasks',
        route: Destinations.adminTasks,
        icon: Icons.schedule,
        title: (l) => l.adminDrawerScheduledTasks,
        description: (l) => l.adminPageDescTasks,
      ),
    ],
  ),
  AdminGroup(
    id: 'library',
    icon: Icons.video_library_outlined,
    title: (l) => l.adminGroupLibrary,
    pages: [
      AdminPage(
        id: 'libraries',
        route: Destinations.adminLibraries,
        icon: Icons.movie_outlined,
        iconAsset: 'assets/icons/clapperboard.png',
        title: (l) => l.adminDrawerLibraries,
        description: (l) => l.adminPageDescLibraries,
      ),
      AdminPage(
        id: 'display',
        route: Destinations.adminSettingsDisplay,
        icon: Icons.grid_view,
        title: (l) => l.adminDrawerDisplay,
        description: (l) => l.adminPageDescDisplay,
        servers: const {ServerType.jellyfin},
      ),
      AdminPage(
        id: 'metadata',
        route: Destinations.adminSettingsMetadata,
        icon: Icons.description_outlined,
        title: (l) => l.adminDrawerMetadata,
        description: (l) => l.adminPageDescMetadata,
      ),
      AdminPage(
        id: 'nfo',
        route: Destinations.adminSettingsNfo,
        icon: Icons.text_snippet_outlined,
        title: (l) => l.adminDrawerNfo,
        description: (l) => l.adminPageDescNfo,
      ),
      AdminPage(
        id: 'live-tv',
        route: Destinations.adminLiveTv,
        icon: Icons.live_tv,
        title: (l) => l.adminDrawerLiveTv,
        description: (l) => l.adminPageDescLiveTv,
      ),
      AdminPage(
        id: 'live-tv-channels',
        route: Destinations.adminLiveTvChannels,
        icon: Icons.format_list_numbered,
        title: (l) => l.adminDrawerLiveTvChannels,
        description: (l) => l.adminPageDescLiveTvChannels,
        servers: const {ServerType.emby},
      ),
      AdminPage(
        id: 'cinema-intros',
        route: Destinations.adminCinemaIntros,
        icon: Icons.theaters_outlined,
        title: (l) => l.adminDrawerCinemaIntros,
        description: (l) => l.adminPageDescCinemaIntros,
        servers: const {ServerType.emby},
      ),
    ],
  ),
  AdminGroup(
    id: 'playback',
    icon: Icons.play_circle_outline,
    title: (l) => l.adminGroupPlayback,
    pages: [
      AdminPage(
        id: 'transcoding',
        route: Destinations.adminSettingsPlayback,
        icon: Icons.swap_horiz,
        title: (l) => l.adminDrawerTranscoding,
        description: (l) => l.adminPageDescTranscoding,
      ),
      AdminPage(
        id: 'resume',
        route: Destinations.adminSettingsResume,
        icon: Icons.play_circle_outline,
        title: (l) => l.adminDrawerResume,
        description: (l) => l.adminPageDescResume,
        servers: const {ServerType.jellyfin},
      ),
      AdminPage(
        id: 'streaming',
        route: Destinations.adminSettingsStreaming,
        icon: Icons.stream,
        title: (l) => l.adminDrawerStreaming,
        description: (l) => l.adminPageDescStreaming,
      ),
      AdminPage(
        id: 'conversions',
        route: Destinations.adminConversions,
        icon: Icons.sync_outlined,
        title: (l) => l.adminDrawerConversions,
        description: (l) => l.adminPageDescConversions,
        servers: const {ServerType.emby},
      ),
      AdminPage(
        id: 'trickplay',
        route: Destinations.adminSettingsTrickplay,
        icon: Icons.view_comfy,
        title: (l) => l.adminDrawerTrickplay,
        description: (l) => l.adminPageDescTrickplay,
        servers: const {ServerType.jellyfin},
      ),
    ],
  ),
  AdminGroup(
    id: 'people',
    icon: Icons.group_outlined,
    title: (l) => l.adminGroupPeople,
    pages: [
      AdminPage(
        id: 'users',
        route: Destinations.adminUsers,
        icon: Icons.people_outline,
        title: (l) => l.adminDrawerUsers,
        description: (l) => l.adminPageDescUsers,
      ),
      AdminPage(
        id: 'devices',
        route: Destinations.adminDevices,
        icon: Icons.devices,
        title: (l) => l.adminDrawerDevices,
        description: (l) => l.adminPageDescDevices,
      ),
      AdminPage(
        id: 'camera-upload',
        route: Destinations.adminCameraUpload,
        icon: Icons.photo_camera_outlined,
        title: (l) => l.adminDrawerCameraUpload,
        description: (l) => l.adminPageDescCameraUpload,
        servers: const {ServerType.emby},
      ),
      AdminPage(
        id: 'dlna',
        route: Destinations.adminDlna,
        icon: Icons.cast_outlined,
        title: (l) => l.adminDrawerDlna,
        description: (l) => l.adminPageDescDlna,
        servers: const {ServerType.emby},
      ),
      AdminPage(
        id: 'api-keys',
        route: Destinations.adminKeys,
        icon: Icons.vpn_key_outlined,
        title: (l) => l.adminDrawerApiKeys,
        description: (l) => l.adminPageDescApiKeys,
      ),
    ],
  ),
  AdminGroup(
    id: 'system',
    icon: Icons.tune,
    title: (l) => l.adminGroupSystem,
    pages: [
      AdminPage(
        id: 'settings',
        route: Destinations.adminSettings,
        icon: Icons.settings_outlined,
        title: (l) => l.adminDrawerSettings,
        description: (l) => l.adminPageDescSettings,
      ),
      AdminPage(
        id: 'branding',
        route: Destinations.adminSettingsBranding,
        icon: Icons.brush_outlined,
        title: (l) => l.adminDrawerBranding,
        description: (l) => l.adminPageDescBranding,
      ),
      AdminPage(
        id: 'networking',
        route: Destinations.adminSettingsNetworking,
        icon: Icons.language,
        title: (l) => l.adminDrawerNetworking,
        description: (l) => l.adminPageDescNetworking,
      ),
      AdminPage(
        id: 'plugins',
        route: Destinations.adminPlugins,
        icon: Icons.extension_outlined,
        title: (l) => l.adminDrawerPlugins,
        description: (l) => l.adminPageDescPlugins,
      ),
      AdminPage(
        id: 'repositories',
        route: Destinations.adminRepositories,
        icon: Icons.source_outlined,
        title: (l) => l.adminDrawerRepositories,
        description: (l) => l.adminPageDescRepositories,
        servers: const {ServerType.jellyfin},
      ),
      AdminPage(
        id: 'backups',
        route: Destinations.adminBackups,
        icon: Icons.backup_outlined,
        title: (l) => l.adminDrawerBackups,
        description: (l) => l.adminPageDescBackups,
      ),
      AdminPage(
        id: 'database',
        route: Destinations.adminDatabase,
        icon: Icons.storage_outlined,
        title: (l) => l.adminDrawerDatabase,
        description: (l) => l.adminPageDescDatabase,
        servers: const {ServerType.emby},
      ),
      AdminPage(
        id: 'premiere',
        route: Destinations.adminPremiere,
        icon: Icons.workspace_premium_outlined,
        title: (l) => l.adminDrawerPremiere,
        description: (l) => l.adminPageDescPremiere,
        servers: const {ServerType.emby},
      ),
      AdminPage(
        id: 'logs',
        route: Destinations.adminLogs,
        icon: Icons.article_outlined,
        title: (l) => l.adminDrawerLogs,
        description: (l) => l.adminPageDescLogs,
      ),
    ],
  ),
];

/// Sub-routes whose path doesn't start with their page's route.
const _extraPrefixes = {'/admin/metadata': 'libraries'};

/// The page a path belongs to: the longest page route that prefixes it, so
/// `/admin/users/123` is Users and `/admin/settings/playback` is Transcoding.
AdminPage? adminPageFor(String path) {
  AdminPage? best;
  for (final group in adminGroups) {
    for (final page in group.pages) {
      final route = page.route;
      final matches = route == Destinations.admin
          ? path == route
          : path == route || path.startsWith('$route/');
      if (matches && (best == null || route.length > best.route.length)) {
        best = page;
      }
    }
  }
  if (best != null) return best;
  for (final entry in _extraPrefixes.entries) {
    if (path.startsWith(entry.key)) return adminPageById(entry.value);
  }
  return null;
}

AdminPage? adminPageById(String id) {
  for (final group in adminGroups) {
    for (final page in group.pages) {
      if (page.id == id) return page;
    }
  }
  return null;
}

AdminGroup adminGroupOf(AdminPage page) =>
    adminGroups.firstWhere((g) => g.pages.contains(page));

AdminGroup? adminGroupById(String id) {
  for (final group in adminGroups) {
    if (group.id == id) return group;
  }
  return null;
}
