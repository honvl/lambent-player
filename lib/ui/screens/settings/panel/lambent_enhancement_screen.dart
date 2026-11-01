part of '../settings_side_panel.dart';

/// This screen's defaults for Lambent Server's PC enhancement. They go out
/// with every PlaybackInfo request, so the first stream already has them; the
/// 4K HDR chip in the player still changes them for the title being watched.
class _LambentEnhancementScreen extends StatelessWidget {
  const _LambentEnhancementScreen();

  @override
  Widget build(BuildContext context) {
    final prefs = GetIt.instance<UserPreferences>();
    String choiceLabel(LambentServerChoice value) => switch (value) {
      LambentServerChoice.server => 'Server setting',
      LambentServerChoice.on => 'On',
      LambentServerChoice.off => 'Off',
    };

    return withCleanSettingsTypography(
      context,
      Scaffold(
        appBar: buildSettingsAppBar(context, const Text('Lambent enhancement')),
        body: ListenableBuilder(
          listenable: prefs,
          builder: (context, _) {
            final on = prefs.get(UserPreferences.lambentEnhanceOnPc);
            final custom = prefs.get(UserPreferences.lambentCustomPicture);
            return ListView(
              children: [
                adaptiveListSection(
                  children: [
                    SwitchPreferenceTile(
                      preference: UserPreferences.lambentEnhanceOnPc,
                      title: 'Enhance on PC',
                      subtitle:
                          'Off plays the original file from Plex. The 4K HDR '
                          'chip in the player can still turn it on for a title.',
                      icon: Icons.auto_awesome,
                    ),
                  ],
                ),
                if (!on &&
                    (PlatformDetection.isAppleTV ||
                        (PlatformDetection.isAndroid && PlatformDetection.isTV))) ...[
                  const _SectionHeader('On this TV'),
                  adaptiveListSection(
                    children: [
                      SwitchPreferenceTile(
                        preference: UserPreferences.lambentClientHdr,
                        title: 'HDR on this TV',
                        subtitle:
                            'SDR titles play as Plex\'s own file and this '
                            'device turns them into HDR10, with Lambent\'s HDR curve.',
                        icon: Icons.hdr_on,
                      ),
                      if (prefs.get(UserPreferences.lambentClientHdr))
                        SwitchPreferenceTile(
                          preference: UserPreferences.lambentClientDeepenBlacks,
                          title: 'Deepen blacks',
                          subtitle: 'Bends a washed-out black floor down to black.',
                          icon: Icons.contrast,
                        ),
                    ],
                  ),
                ],
                if (on) ...[
                  const _SectionHeader('HDR'),
                  adaptiveListSection(
                    children: [
                      EnumPreferenceTile<LambentServerChoice>(
                        preference: UserPreferences.lambentRtxHdr,
                        title: 'RTX HDR',
                        icon: Icons.hdr_on,
                        labelOf: choiceLabel,
                      ),
                      EnumPreferenceTile<LambentServerChoice>(
                        preference: UserPreferences.lambentDolbyVision,
                        title: 'Dolby Vision',
                        icon: Icons.hdr_auto,
                        labelOf: choiceLabel,
                      ),
                      EnumPreferenceTile<LambentServerChoice>(
                        preference: UserPreferences.lambentDeepenBlacks,
                        title: 'Deepen blacks',
                        icon: Icons.contrast,
                        labelOf: choiceLabel,
                      ),
                    ],
                  ),
                  const _SectionHeader('Picture'),
                  adaptiveListSection(
                    children: [
                      SwitchPreferenceTile(
                        preference: UserPreferences.lambentCustomPicture,
                        title: 'Custom picture on this screen',
                        subtitle: 'Off follows the server\'s picture settings.',
                        icon: Icons.tune,
                      ),
                      if (custom) ...[
                        SliderPreferenceTile(
                          preference: UserPreferences.lambentSaturation,
                          title: 'Saturation',
                          icon: Icons.palette_outlined,
                          min: 0,
                          max: 200,
                          divisions: 20,
                          labelOf: (v) => '$v',
                        ),
                        SliderPreferenceTile(
                          preference: UserPreferences.lambentContrast,
                          title: 'Contrast',
                          description: 'RTX HDR only',
                          icon: Icons.contrast,
                          min: 0,
                          max: 200,
                          divisions: 20,
                          labelOf: (v) => '$v',
                        ),
                        SliderPreferenceTile(
                          preference: UserPreferences.lambentBrightness,
                          title: 'Brightness',
                          description: 'RTX HDR only (middle grey)',
                          icon: Icons.brightness_6,
                          min: 10,
                          max: 100,
                          divisions: 18,
                          labelOf: (v) => '$v nits',
                        ),
                        SliderPreferenceTile(
                          preference: UserPreferences.lambentPeak,
                          title: 'Peak brightness',
                          description: 'RTX HDR only',
                          icon: Icons.wb_sunny_outlined,
                          min: 400,
                          max: 1400,
                          divisions: 20,
                          labelOf: (v) => '$v nits',
                        ),
                        SliderPreferenceTile(
                          preference: UserPreferences.lambentHue,
                          title: 'Hue',
                          icon: Icons.color_lens_outlined,
                          min: -30,
                          max: 30,
                          divisions: 12,
                          labelOf: (v) => '$v°',
                        ),
                        SliderPreferenceTile(
                          preference: UserPreferences.lambentWideColour,
                          title: 'Wide colour',
                          description:
                              "RTX HDR only: vivid colours toward HDR's wider range; skin stays",
                          icon: Icons.palette_outlined,
                          min: 0,
                          max: 100,
                          divisions: 4,
                          labelOf: (v) => v == 0 ? 'Off' : '$v%',
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
