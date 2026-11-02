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
                const _EnhanceSubscriptionSection(),
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

/// Lambent Enhance on the signed-in server (ENTITLEMENTS.md section 7): what
/// the server says, the store's subscriptions in store builds, and the
/// server's own buy page in sideloaded Android builds. Shows nothing for a
/// server that is not Lambent Server.
class _EnhanceSubscriptionSection extends StatelessWidget {
  const _EnhanceSubscriptionSection();

  /// Sideloaded Android may send people to the server's checkout page; store
  /// builds sell only through their store, and iOS and Apple TV builds
  /// without a store link out to nothing.
  static bool get _mayLinkOut =>
      PlatformDetection.isAndroid &&
      switch (AppDistribution.channel) {
        DistributionChannel.aab || DistributionChannel.androidTvAab => false,
        _ => true,
      };

  @override
  Widget build(BuildContext context) {
    final purchases = LambentEnhanceService.instance.current;
    if (purchases == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: purchases,
      builder: (context, _) {
        if (!purchases.isLambentServer) return const SizedBox.shrink();
        final licence = purchases.licence;
        final locale = Localizations.localeOf(context).toLanguageTag();
        String date(DateTime d) => DateFormat.yMMMd(locale).format(d);
        final needsEnhance = licence == null || !licence.enhanced;
        final buyUrl = licence?.buyUrl;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionHeader('Lambent Enhance'),
            adaptiveListSection(
              children: [
                ListTile(
                  leading: Icon(
                    licence?.enhanced == true
                        ? Icons.verified_rounded
                        : Icons.auto_awesome_outlined,
                  ),
                  title: Text(
                    licence?.headline ?? 'Checking your Lambent Server…',
                  ),
                  subtitle: switch (licence?.detail(date)) {
                    final d? => Text(d),
                    null => null,
                  },
                  trailing: purchases.busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                ),
                if (needsEnhance && purchases.canBuyInApp)
                  for (final product in purchases.products)
                    ListTile(
                      leading: const Icon(Icons.shopping_bag_outlined),
                      title: Text(
                        product.yearly
                            ? 'Lambent Enhance, yearly'
                            : 'Lambent Enhance, monthly',
                      ),
                      subtitle: Text(
                        '${product.price} '
                        '${product.yearly ? 'a year' : 'a month'}, for '
                        'every screen on your server',
                      ),
                      enabled: !purchases.busy,
                      onTap: () => purchases.buy(product),
                    ),
                if (purchases.store != null)
                  ListTile(
                    leading: const Icon(Icons.restore_rounded),
                    title: const Text('Restore purchases'),
                    enabled: !purchases.busy,
                    onTap: purchases.restore,
                  ),
                if (needsEnhance && _mayLinkOut && buyUrl != null)
                  ListTile(
                    leading: const Icon(Icons.open_in_new_rounded),
                    title: const Text('Get Lambent Enhance'),
                    subtitle: const Text('Opens the checkout for your server'),
                    onTap: () => launchUrl(
                      buyUrl,
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                if (purchases.message case final message?)
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded),
                    title: Text(message),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
