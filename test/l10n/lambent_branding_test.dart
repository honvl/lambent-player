import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/l10n/lambent_localizations.dart';
import 'package:moonfin/l10n/lambent_strings.dart';

/// Upstream's translation files keep Moonfin's name; Lambent's goes in as the
/// strings load (tool/gen_lambent_l10n.py).
void main() {
  Future<AppLocalizations> load(String language) =>
      LambentLocalizations.delegate.load(Locale(language));

  test('the app is called Lambent in every language', () async {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = await LambentLocalizations.delegate.load(locale);
      expect(l10n.appTitle, isNot(contains('Moonfin')), reason: '$locale');
      expect(l10n.recommendationSystemMoonfin, isNot(contains('Moonfin')),
          reason: '$locale');
      expect(l10n.recommendationSystemMoonfin, isNot(contains('Мунфин')),
          reason: '$locale');
    }
  });

  test('upstream says Moonfin where Lambent shows its own name', () async {
    final upstream = await AppLocalizations.delegate.load(const Locale('en'));
    final l10n = await load('en');
    expect(upstream.recommendationSystemMoonfin, 'Moonfin Recommends');
    expect(l10n.recommendationSystemMoonfin, 'Lambent Recommends');
  });

  test('Moonfin stays where it names the folder or the plugin', () async {
    final l10n = await load('en');
    expect(l10n.downloadsVisibleToOtherApps, contains('Downloads/Moonfin'));
    expect(l10n.settingsSupportMoonfin, contains('Moonfin'));
    expect(l10n.savedThemesDescription, contains('Moonfin plugin'));
  });

  test("Lambent's own wording", () async {
    final en = await load('en');
    expect(en.sourceCodeUrl, 'https://github.com/honvl/lambent-player');
    expect(
      en.settingsPlaybackSubtitle,
      'Player, quality, audio, subtitles, and skipping',
    );
    expect(en.moreFromStudio('A24'), 'More from A24');
    final de = await load('de');
    expect(de.sourceCodeUrl, 'https://github.com/honvl/lambent-player');
    expect(de.settingsPlaybackSubtitle, isNot(contains('Moonfin')));
  });

  test('project names and compounds', () {
    expect(
      lambentBranded('https://github.com/Moonfin-Client/Moonfin-Core'),
      'https://github.com/Moonfin-Client/Moonfin-Core',
    );
    expect(
      lambentBranded('Kohdetta ei löydy Moonfin-kirjastostasi'),
      'Kohdetta ei löydy Lambent-kirjastostasi',
    );
    expect(lambentBranded("Moonfin's theme"), "Lambent's theme");
    expect(lambentBranded('Мунфинове препоруке'), 'Ламбентове препоруке');
  });
}
