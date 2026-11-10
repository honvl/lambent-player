import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:playback_core/playback_core.dart';

import '../playback/lossless_audio_bridge.dart';
import '../preference/preference_constants.dart';
import '../preference/user_preferences.dart';
import 'display_refresh.dart';
import 'platform_detection.dart';

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
  final strength = prefs.get(UserPreferences.lambentHdrStrength);
  // A TV smooths motion itself, so it never asks.
  final interpolate2D =
      !PlatformDetection.isTV &&
      prefs.get(UserPreferences.lambentInterpolate2D);
  // With it, the screen's refresh rate: the PC makes the in-between frames at
  // a rate it shows evenly (24 fps as 60 on a 60 or 120 Hz screen).
  final displayHz = interpolate2D ? DisplayRefresh.hz : null;
  // The same rule as direct play: the PC keeps a lossless track lossless, as
  // FLAC, where this route takes the PCM it becomes.
  final lossless = usesLosslessAudioBridge(
    prefs.detectedAudioCapabilities,
    maxAudioChannels: prefs.resolveMaxAudioChannels(),
    downmixToStereo: prefs.get(UserPreferences.downmixToStereo),
  );
  // What this route hands its receiver untouched: the PC copies that track
  // into the stream, Atmos and DTS:X included.
  final passthrough = [
    if (prefs.resolveTrueHdPassthroughEnabled()) 'truehd',
    if (prefs.resolveDtsHdPassthroughEnabled()) 'dtshd',
    if (prefs.resolveDtsCorePassthroughEnabled()) 'dts',
  ];
  return {
    // A browser refuses a whole stream over a sound format it doesn't take, and
    // has no upscaler of its own, so the PC makes the screen's whole picture.
    if (kIsWeb) ...{'AacAudio': true, 'Browser': true},
    if (lossless) 'LosslessAudio': true,
    if (passthrough.isNotEmpty) 'PassthroughAudio': passthrough,
    // Of its own, not with the custom picture: the player's slider sets it.
    if (strength != UserPreferences.lambentHdrStrength.defaultValue)
      'Strength': strength,
    'RtxHdr': ?hdr,
    'DolbyVision': ?dv,
    'DeepenBlacks': ?blacks,
    if (interpolate2D) 'Interpolate2D': true,
    'DisplayHz': ?displayHz,
    // Brightness (middle grey), hue and wide colour are no longer the screen's to set (the owner, 2026-11-08): HDR strength does
    // brightness's job, and the PC applies wide colour itself where NVIDIA's HDR model runs.
    if (custom) ...{
      'Saturation': prefs.get(UserPreferences.lambentSaturation),
      'Contrast': prefs.get(UserPreferences.lambentContrast),
      'Peak': prefs.get(UserPreferences.lambentPeak),
    },
  };
}

/// Keeps [LambentEnhancement]'s screen defaults in step with the settings.
///
/// "Enhance on PC" only resets the player's on/off when that setting itself
/// changes, so turning enhancement off from the 4K HDR chip survives an
/// unrelated settings change.
void bindLambentEnhancementDefaults(UserPreferences prefs) {
  LambentEnhancement.dolbyVisionWithHdr = !kIsWeb;
  // A build made with --dart-define=LAMBENT_ORIGINAL=true plays Plex's own
  // file, which a simulator can decode where it can't the enhanced HEVC HDR
  // stream.
  const forceOriginal = bool.fromEnvironment('LAMBENT_ORIGINAL');
  var enhanceOn =
      prefs.get(UserPreferences.lambentEnhanceOnPc) && !forceOriginal;
  LambentEnhancement.enhancementOff = !enhanceOn;
  LambentEnhancement.screenDefaults = () => lambentScreenDefaults(prefs);
  if (!PlatformDetection.isTV) DisplayRefresh.measure();
  prefs.addListener(() {
    final now = prefs.get(UserPreferences.lambentEnhanceOnPc);
    if (now != enhanceOn) {
      enhanceOn = now;
      // Without Enhance the setting has nothing to turn on.
      if (!LambentEnhancement.compareOnly) {
        LambentEnhancement.enhancementOff = !now;
      }
    }
  });
}

/// Follows the server's Lambent Enhance licence. Without Enhance or a trial
/// the PC may only show its picture beside the original: playback opens on
/// the original file, and turning enhancement on in the player opens the
/// split-screen compare. Buying (or a trial) gives back the screen's own
/// "Enhance on PC" setting.
void applyLambentLicence({
  required bool compareOnly,
  required UserPreferences prefs,
}) {
  if (compareOnly == LambentEnhancement.compareOnly) return;
  LambentEnhancement.compareOnly = compareOnly;
  LambentEnhancement.enhancementOff =
      compareOnly ||
      !prefs.get(UserPreferences.lambentEnhanceOnPc) ||
      const bool.fromEnvironment('LAMBENT_ORIGINAL');
}
