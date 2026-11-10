/// Switches for Moonfin-owned surfaces that Lambent does not ship.
///
/// Flip a value to `true` to bring the surface back. Both default to off
/// because they point at the original Moonfin project (its donation page,
/// Discord, issue tracker and GitHub releases), not at Lambent.
class LambentBrand {
  const LambentBrand._();

  /// About screen rows that send the user to Moonfin's developer: "Join the
  /// Discord", "Support Moonfin" (Buy Me a Coffee) and "Report an issue"
  /// (Moonfin-Client issue tracker). Also hides the privacy policy row, which
  /// opens moonfin.io/privacy; point it at a Lambent policy before re-enabling
  /// it for Lambent.
  static const bool showMoonfinDeveloperLinks = false;

  /// The in-app update check (startup banner, About "Check for updates" row,
  /// settings search entry). It reads Moonfin-Client's GitHub releases, so it
  /// would offer Moonfin builds over Lambent ones.
  static const bool enableAppUpdateCheck = false;

  /// The server admin panel and the details page's admin actions (identify,
  /// change artwork, delete). Lambent Server administers itself and leaves the
  /// library to Plex, so none of the Jellyfin admin endpoints behind these
  /// exist there and every one of them would fail.
  static const bool enableServerAdmin = false;

  /// Push notifications through Firebase Cloud Messaging. Moonfin's Firebase
  /// project is not Lambent's, so its config is gone from every build and the
  /// service never starts; set up a Lambent project before turning this on.
  static const bool enablePushMessaging = false;

  /// Retro games and their emulator cores. Several cores' licences bar
  /// commercial use and Lambent is sold, so its builds carry none, download
  /// none and show no game libraries. Not const so that the game code's tests
  /// can run: `test/flutter_test_config.dart` turns it on.
  static bool enableGames = false;

  /// Upstream's "Save to Downloads folder" on Android, which puts downloads in
  /// the shared Downloads folder through MediaStore. Finding them again after a
  /// reinstall takes READ_MEDIA_VIDEO and READ_MEDIA_AUDIO, which Google Play
  /// allows only when broad media access is the app's core purpose, so Lambent
  /// asks for neither and keeps every download in the app's own storage.
  static const bool enablePublicDownloadsFolder = false;

  /// This app's own source, which GPL-2.0 has us publish.
  static const String sourceUrl = 'https://github.com/honvl/lambent-player';
}
