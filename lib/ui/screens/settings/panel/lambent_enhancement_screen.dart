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
          // The licence decides whether "Enhance on PC" is offered.
          listenable: Listenable.merge([
            prefs,
            ?LambentEnhanceService.instance.current,
          ]),
          builder: (context, _) {
            final on = prefs.get(UserPreferences.lambentEnhanceOnPc);
            final custom = prefs.get(UserPreferences.lambentCustomPicture);
            return ListView(
              children: [
                const _EnhanceSubscriptionSection(),
                // Without Enhance or a trial titles always open on the
                // original; the player's chip offers the compare.
                if (!LambentEnhancement.compareOnly)
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
                        title: 'Auto HDR',
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
                      SliderPreferenceTile(
                        preference: UserPreferences.lambentHdrStrength,
                        title: 'HDR strength',
                        description: 'Lower brings the brightest parts down.',
                        icon: Icons.brightness_6_outlined,
                        min: 0,
                        max: 100,
                        divisions: 10,
                        labelOf: (v) => '$v%',
                      ),
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
                          description: 'Auto HDR only',
                          icon: Icons.contrast,
                          min: 0,
                          max: 200,
                          divisions: 20,
                          labelOf: (v) => '$v',
                        ),
                        SliderPreferenceTile(
                          preference: UserPreferences.lambentPeak,
                          title: 'Peak brightness',
                          description: 'Auto HDR only',
                          icon: Icons.wb_sunny_outlined,
                          min: 400,
                          max: 1400,
                          divisions: 20,
                          labelOf: (v) => '$v nits',
                        ),
                      ],
                    ],
                  ),
                  // A TV smooths motion itself, so it is never asked.
                  if (!PlatformDetection.isTV) ...[
                    const _SectionHeader('Motion'),
                    adaptiveListSection(
                      children: [
                        SwitchPreferenceTile(
                          preference: UserPreferences.lambentInterpolate2D,
                          title: 'Frame interpolation',
                          subtitle:
                              'Smoother motion: films up to 30 fps play at twice '
                              'their rate where your PC can make the frames.',
                          icon: Icons.animation,
                        ),
                      ],
                    ),
                  ],
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
class _EnhanceSubscriptionSection extends StatefulWidget {
  const _EnhanceSubscriptionSection();

  @override
  State<_EnhanceSubscriptionSection> createState() =>
      _EnhanceSubscriptionSectionState();
}

class _EnhanceSubscriptionSectionState
    extends State<_EnhanceSubscriptionSection> {
  /// Sideloaded Android may send people to the server's checkout page; store
  /// builds sell only through their store, and iOS and Apple TV builds
  /// without a store link out to nothing.
  static bool get _mayLinkOut =>
      // The Mac build is distributed directly, with no store to sell through.
      PlatformDetection.isMacOS ||
      PlatformDetection.isAndroid &&
          switch (AppDistribution.channel) {
            DistributionChannel.aab ||
            DistributionChannel.androidTvAab => false,
            _ => true,
          };

  @override
  void initState() {
    super.initState();
    // The store may have had nothing to offer at launch (offline, or not
    // signed in to the App Store yet).
    LambentEnhanceService.instance.current?.loadProducts();
  }

  @override
  Widget build(BuildContext context) {
    final purchases = LambentEnhanceService.instance.current;
    if (purchases == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: purchases,
      builder: (context, _) {
        if (!purchases.isLambentServer) {
          return _PlayerEnhanceSection(
            purchases: purchases,
            mayLinkOut: _mayLinkOut,
          );
        }
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
                    _EnhanceActionTile(
                      leading: const Icon(Icons.shopping_bag_outlined),
                      title: Text(
                        product.lifetime
                            ? 'Lambent Enhance, lifetime'
                            : product.yearly
                            ? 'Lambent Enhance, yearly'
                            : 'Lambent Enhance, monthly',
                      ),
                      subtitle: Text(
                        '${product.price} '
                        '${product.lifetime ? 'once' : (product.yearly ? 'a year' : 'a month')}, for '
                        'every screen on your server',
                      ),
                      enabled: !purchases.busy,
                      onTap: () => purchases.buy(product),
                    ),
                if (purchases.store != null)
                  _EnhanceActionTile(
                    leading: const Icon(Icons.restore_rounded),
                    title: const Text('Restore purchases'),
                    enabled: !purchases.busy,
                    onTap: purchases.restore,
                  ),
                if (needsEnhance && _mayLinkOut && buyUrl != null)
                  _EnhanceActionTile(
                    leading: const Icon(Icons.open_in_new_rounded),
                    title: const Text('Get Lambent Enhance'),
                    subtitle: const Text('Opens the checkout for your server'),
                    onTap: () =>
                        launchUrl(buyUrl, mode: LaunchMode.externalApplication),
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

/// Lambent Enhance on this device, signed in to a server that is not Lambent
/// Server (ENTITLEMENTS.md section 8): what it holds and what it can run, said
/// before anyone pays. A device that can run neither the AI upscaler nor the
/// HDR lift is offered nothing.
class _PlayerEnhanceSection extends StatefulWidget {
  const _PlayerEnhanceSection({
    required this.purchases,
    required this.mayLinkOut,
  });

  final EnhancePurchases purchases;
  final bool mayLinkOut;

  @override
  State<_PlayerEnhanceSection> createState() => _PlayerEnhanceSectionState();
}

class _PlayerEnhanceSectionState extends State<_PlayerEnhanceSection> {
  late final Future<LambentDeviceCapabilities> _capabilities =
      LambentDeviceCapabilities.detect();

  @override
  void initState() {
    super.initState();
    // A checkout in the browser, or a licence from another device, shows here.
    widget.purchases.player?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final purchases = widget.purchases;
    final player = purchases.player;
    if (player == null) return const SizedBox.shrink();
    return FutureBuilder<LambentDeviceCapabilities>(
      future: _capabilities,
      builder: (context, snapshot) {
        final can = snapshot.data ?? LambentDeviceCapabilities.none;
        if (!can.worthBuying) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: player,
          builder: (context, _) {
            final locale = Localizations.localeOf(context).toLanguageTag();
            final until = player.until;
            final date = until == null
                ? null
                : DateFormat.yMMMd(locale).format(until);
            final state = player.state;
            final buyUrl = player.buyUrl;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SectionHeader('Lambent Enhance'),
                adaptiveListSection(
                  children: [
                    ListTile(
                      leading: Icon(
                        player.licensed
                            ? Icons.verified_rounded
                            : Icons.auto_awesome_outlined,
                      ),
                      title: Text(switch (state) {
                        EnhanceState.active => 'Lambent Enhance is on',
                        EnhanceState.trial => 'Lambent Enhance: free trial',
                        _ => 'Lambent Enhance',
                      }),
                      subtitle: Text(
                        [
                          'This device runs ${can.summary}.',
                          if (date != null)
                            state == EnhanceState.trial
                                ? 'Trial ends $date.'
                                : 'Until $date.',
                        ].join(' '),
                      ),
                    ),
                    if (state != EnhanceState.active && purchases.canBuyInApp)
                      for (final product in purchases.products)
                        _EnhanceActionTile(
                          leading: const Icon(Icons.shopping_bag_outlined),
                          title: Text(
                            product.lifetime
                                ? 'Lambent Enhance, lifetime'
                                : product.yearly
                                ? 'Lambent Enhance, yearly'
                                : 'Lambent Enhance, monthly',
                          ),
                          subtitle: Text(
                            '${product.price} '
                            '${product.lifetime ? 'once' : (product.yearly ? 'a year' : 'a month')}',
                          ),
                          enabled: !purchases.busy,
                          onTap: () => purchases.buy(product),
                        ),
                    if (purchases.store != null)
                      _EnhanceActionTile(
                        leading: const Icon(Icons.restore_rounded),
                        title: const Text('Restore purchases'),
                        enabled: !purchases.busy,
                        onTap: purchases.restore,
                      ),
                    if (state != EnhanceState.active &&
                        widget.mayLinkOut &&
                        buyUrl != null)
                      _EnhanceActionTile(
                        leading: const Icon(Icons.open_in_new_rounded),
                        title: const Text('Get Lambent Enhance'),
                        subtitle: const Text(
                          'Opens the checkout for this device',
                        ),
                        onTap: () => launchUrl(
                          buyUrl,
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    _EnhanceActionTile(
                      leading: const Icon(Icons.login_rounded),
                      title: const Text('Already bought it? Sign in'),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => _PlayerSignInDialog(player: player),
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
      },
    );
  }
}

/// Joins this player to a Lambent account: an email with a link, whose page
/// shows the code to paste here.
class _PlayerSignInDialog extends StatefulWidget {
  const _PlayerSignInDialog({required this.player});

  final PlayerLicence player;

  @override
  State<_PlayerSignInDialog> createState() => _PlayerSignInDialogState();
}

class _PlayerSignInDialogState extends State<_PlayerSignInDialog> {
  final _field = TextEditingController();
  bool _emailSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    final text = _field.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_emailSent) {
        await widget.player.joinAccount(text);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      await widget.player.requestSignIn(text);
      _field.clear();
      _emailSent = true;
    } on LicenceException catch (e) {
      _error = e.message ?? "Lambent couldn't be reached. Try again later.";
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Sign in to Lambent'),
    content: TextField(
      controller: _field,
      autofocus: true,
      decoration: InputDecoration(
        labelText: _emailSent ? 'Code from the email\'s page' : 'Email',
        errorText: _error,
      ),
      onSubmitted: (_) => _next(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _next,
        child: Text(_emailSent ? 'Sign in' : 'Send email'),
      ),
    ],
  );
}

/// A row in the Lambent Enhance section that does something when chosen. A
/// plain [ListTile]'s focus tint can't be seen from a sofa, so this draws the
/// settings rows' own focus, which is what tells someone with a remote which
/// plan they are about to buy.
class _EnhanceActionTile extends StatelessWidget {
  const _EnhanceActionTile({
    this.leading,
    required this.title,
    this.subtitle,
    this.enabled = true,
    this.onTap,
  });

  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      enabled: enabled,
      builder: (context, focused) {
        final invert = focused && settingsTileInvertsOnFocus;
        return ListTile(
          enabled: enabled,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          textColor: invert ? AppColors.black.withValues(alpha: 0.87) : null,
          iconColor: invert ? AppColors.black.withValues(alpha: 0.7) : null,
          leading: leading,
          title: title,
          subtitle: subtitle,
          onTap: onTap,
        );
      },
    );
  }
}
