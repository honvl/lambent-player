import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../util/platform_detection.dart';
import 'sign_in_qr_code.dart';

/// The page that says how to install Lambent Server.
const lambentServerSetupUrl = 'https://getlambent.app/start';
const lambentServerSetupAddress = 'getlambent.app/start';

/// Says where to get Lambent Server, for someone with no server yet. A TV
/// can't open a link, so it shows a QR code and the short address; other
/// screens get a button.
class LambentServerSetupCard extends StatelessWidget {
  final Color foreground;

  const LambentServerSetupCard({super.key, required this.foreground});

  @override
  Widget build(BuildContext context) {
    final isTv = PlatformDetection.isTV;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'New to Lambent?',
          style: TextStyle(
            color: foreground,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Install the free Lambent Server on your PC or Mac, and it shows up '
          'here by itself. Already have Plex or Jellyfin? Add it below.',
          style: TextStyle(
            color: foreground.withValues(alpha: 0.7),
            fontSize: 14,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 10),
        if (isTv)
          Text(
            lambentServerSetupAddress,
            style: TextStyle(
              color: foreground,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          )
        else
          OutlinedButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(lambentServerSetupUrl),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Get Lambent Server'),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: isTv
          ? Row(
              children: [
                const ExcludeSemantics(
                  child: SignInQrCode(data: lambentServerSetupUrl, size: 104),
                ),
                const SizedBox(width: 16),
                Expanded(child: text),
              ],
            )
          : text,
    );
  }
}
