import 'app_localizations.dart';

/// Lambent's own strings, which upstream's translation files don't have.
/// English only for now; keeping them out of the .arb files keeps those
/// exactly as upstream ships them.
extension LambentStrings on AppLocalizations {
  /// Status under an active download whose connection to the server dropped;
  /// it resumes on its own once the server can be reached.
  String get downloadWaitingForServer =>
      'Waiting for the server. The download picks up where it stopped.';

  /// Detail page row of other titles from the same studio, as Plex titles it.
  String moreFromStudio(String name) => 'More from $name';

  /// Detail page row of other titles with the same actor, as Plex titles it.
  String moreWithPerson(String name) => 'More with $name';
}
