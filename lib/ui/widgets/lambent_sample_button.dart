import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../navigation/destinations.dart';
import '../screens/lambent_sample/lambent_sample.dart';

/// Opens the "See the difference" sample: what Lambent Server's enhancement
/// looks like, for someone who hasn't got a PC running it (yet). Nothing where
/// the sample can't play.
class LambentSampleButton extends StatelessWidget {
  const LambentSampleButton({super.key, required this.foreground});

  final Color foreground;

  @override
  Widget build(BuildContext context) {
    if (!LambentSample.available) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'See what Lambent does',
            style: TextStyle(
              color: foreground,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'A short film clip, the original beside Lambent\'s picture.',
            style: TextStyle(
              color: foreground.withValues(alpha: 0.7),
              fontSize: 14,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            // A remote has no pointer: a focused button must be plain to see.
            style: ButtonStyle(
              side: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      )
                    : null,
              ),
            ),
            // A remote moving onto it brings it into view, as the list's
            // other rows do.
            onFocusChange: (focused) {
              if (!focused) return;
              Scrollable.ensureVisible(
                context,
                alignment: 0.5,
                duration: const Duration(milliseconds: 200),
              );
            },
            onPressed: () => context.push(Destinations.lambentSample),
            icon: const Icon(Icons.compare_rounded, size: 18),
            label: const Text('See the difference'),
          ),
        ],
      ),
    );
  }
}
