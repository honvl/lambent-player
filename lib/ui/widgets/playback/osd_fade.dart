import 'package:flutter/widgets.dart';

/// Fades the player's controls in and out, the way Netflix's do: a quick
/// fade in, a slower one out.
///
/// [child] is the controls while they're shown and null once they're hidden.
/// While they fade out this keeps drawing the last controls it was given, so
/// their state (and the bar's layout) holds until they're gone, but they
/// take no focus or taps from the moment they start to go.
class OsdFade extends StatefulWidget {
  const OsdFade({super.key, required this.child});

  final Widget? child;

  static const fadeIn = Duration(milliseconds: 200);
  static const fadeOut = Duration(milliseconds: 450);

  @override
  State<OsdFade> createState() => _OsdFadeState();
}

class _OsdFadeState extends State<OsdFade> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: OsdFade.fadeIn,
    reverseDuration: OsdFade.fadeOut,
  )..addStatusListener(_onStatus);

  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeInOut,
  );

  Widget? _last;

  @override
  void initState() {
    super.initState();
    _last = widget.child;
    if (_last != null) _controller.forward();
  }

  @override
  void didUpdateWidget(OsdFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    final child = widget.child;
    if (child != null) {
      _last = child;
      _controller.forward();
    } else if (oldWidget.child != null) {
      _controller.reverse();
    }
  }

  void _onStatus(AnimationStatus status) {
    // Gone for good once faded out, so nothing hidden stays in the tree.
    if (status == AnimationStatus.dismissed && widget.child == null) {
      setState(() => _last = null);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _last;
    if (last == null) return const SizedBox.shrink();
    final leaving = widget.child == null;
    return IgnorePointer(
      ignoring: leaving,
      child: ExcludeFocus(
        excluding: leaving,
        child: FadeTransition(opacity: _opacity, child: last),
      ),
    );
  }
}
