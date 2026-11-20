import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/local_files/local_file_library.dart';
import '../../l10n/app_localizations.dart';
import '../navigation/destinations.dart';

/// Opens "On this device" from the server screen, so a film saved on the
/// phone or tablet plays with no server at all. Nothing where local files
/// aren't supported.
class LocalFilesButton extends StatelessWidget {
  const LocalFilesButton({super.key, required this.foreground});

  final Color foreground;

  @override
  Widget build(BuildContext context) {
    if (!LocalFileLibrary.isSupported) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.localFilesServerScreenTitle,
            style: TextStyle(
              color: foreground,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.localFilesServerScreenDetail,
            style: TextStyle(
              color: foreground.withValues(alpha: 0.7),
              fontSize: 14,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => context.push(Destinations.localFiles),
            icon: const Icon(Icons.folder_open, size: 18),
            label: Text(l10n.onThisDevice),
          ),
        ],
      ),
    );
  }
}
