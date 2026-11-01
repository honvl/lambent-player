import 'package:playback_core/playback_core.dart';

import '../preference/preference_constants.dart';
import '../preference/user_preferences.dart';

/// This screen's Lambent enhancement defaults, as PlaybackInfo's `Lambent`
/// object. Settings left on "server" are left out, so the server decides.
Map<String, Object> lambentScreenDefaults(UserPreferences prefs) {
  bool? choice(LambentServerChoice value) => switch (value) {
    LambentServerChoice.server => null,
    LambentServerChoice.on => true,
    LambentServerChoice.off => false,
  };

  final hdr = choice(prefs.get(UserPreferences.lambentRtxHdr));
  final dv = choice(prefs.get(UserPreferences.lambentDolbyVision));
  final blacks = choice(prefs.get(UserPreferences.lambentDeepenBlacks));
  final custom = prefs.get(UserPreferences.lambentCustomPicture);
  return {
    'RtxHdr': ?hdr,
    'DolbyVision': ?dv,
    'DeepenBlacks': ?blacks,
    if (custom) ...{
      'Saturation': prefs.get(UserPreferences.lambentSaturation),
      'Contrast': prefs.get(UserPreferences.lambentContrast),
      'Brightness': prefs.get(UserPreferences.lambentBrightness),
      'Peak': prefs.get(UserPreferences.lambentPeak),
      'Hue': prefs.get(UserPreferences.lambentHue),
      'Gamut': prefs.get(UserPreferences.lambentWideColour),
    },
  };
}

/// Keeps [LambentEnhancement]'s screen defaults in step with the settings.
///
/// "Enhance on PC" only resets the player's on/off when that setting itself
/// changes, so turning enhancement off from the 4K HDR chip survives an
/// unrelated settings change.
void bindLambentEnhancementDefaults(UserPreferences prefs) {
  var enhanceOn = prefs.get(UserPreferences.lambentEnhanceOnPc);
  LambentEnhancement.enhancementOff = !enhanceOn;
  LambentEnhancement.screenDefaults = lambentScreenDefaults(prefs);
  prefs.addListener(() {
    final now = prefs.get(UserPreferences.lambentEnhanceOnPc);
    if (now != enhanceOn) {
      enhanceOn = now;
      LambentEnhancement.enhancementOff = !now;
    }
    LambentEnhancement.screenDefaults = lambentScreenDefaults(prefs);
  });
}
