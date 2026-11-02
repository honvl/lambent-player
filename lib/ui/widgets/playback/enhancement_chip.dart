import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:playback_core/playback_core.dart';

/// The label for the "enhanced" chip in the TV player, or null when
/// [streamUrl] isn't a Lambent Server enhanced stream.
///
/// Lambent Server states the enhancement in the URL itself:
/// `/v1/enhanced/...?hdr=1&maxh=2160`. `maxh` is the delivered height
/// (2160 reads "4K", anything else "Np") and `hdr=1` appends " HDR". A URL
/// that is enhanced but carries neither reads "Enhanced".
String? lambentEnhancementLabel(String? streamUrl) {
  if (streamUrl == null || streamUrl.isEmpty) return null;
  final uri = Uri.tryParse(streamUrl);
  if (uri == null || !uri.path.contains('/v1/enhanced/')) return null;

  // Match on a lowered key; servers differ on casing.
  final query = <String, String>{
    for (final entry in uri.queryParameters.entries)
      entry.key.toLowerCase(): entry.value.trim().toLowerCase(),
  };
  final height = int.tryParse(query['maxh'] ?? '');
  final hdr = query['hdr'] == '1' || query['hdr'] == 'true';

  final resolution = (height == null || height <= 0)
      ? null
      : height == 2160
      ? '4K'
      : '${height}p';
  final parts = [?resolution, if (hdr) 'HDR'];
  return parts.isEmpty ? 'Enhanced' : parts.join(' ');
}

/// [label] with the plan's upscale on this device after it ("1080p HDR ·
/// AI upscale"), while [deviceUpscale] runs and the stream's plan asks for
/// it (`cup`; LambentEnhancement.clientUpscaleLines). Otherwise [label].
String? withDeviceUpscale(
  String? label,
  String? streamUrl,
  String? deviceUpscale,
) {
  if (label == null || deviceUpscale == null) return label;
  if (LambentEnhancement.clientUpscaleLines(streamUrl) == null) return label;
  return '$label · $deviceUpscale';
}

/// The capsule on the glass player bar that says the stream is enhanced:
/// white 10% fill, 1.5px white 14% rim and an amber dot with a soft glow.
///
/// Focusable like the other TV buttons. Right stops here, since it is the last
/// stop on the bar; [onLeft] hands focus back to the buttons beside it.
class EnhancementChip extends StatefulWidget {
  const EnhancementChip({
    super.key,
    required this.label,
    required this.height,
    required this.accent,
    this.fontSize = 16,
    this.focusNode,
    this.onPressed,
    this.onLeft,
  });

  final String label;

  /// The slot height; the capsule rests a little inside it, like the round
  /// buttons next to it, and fills it when focused.
  final double height;
  final Color accent;
  final double fontSize;
  final FocusNode? focusNode;
  final VoidCallback? onPressed;
  final VoidCallback? onLeft;

  @override
  State<EnhancementChip> createState() => _EnhancementChipState();
}

class _EnhancementChipState extends State<EnhancementChip> {
  late FocusNode _node;
  bool _ownsNode = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _attachNode();
  }

  void _attachNode() {
    final provided = widget.focusNode;
    _node = provided ?? FocusNode(debugLabel: 'video_player_tv_enhancement');
    _ownsNode = provided == null;
    _node.addListener(_onFocusChange);
    _focused = _node.hasFocus;
  }

  @override
  void didUpdateWidget(EnhancementChip old) {
    super.didUpdateWidget(old);
    if (widget.focusNode != old.focusNode) {
      _node.removeListener(_onFocusChange);
      if (_ownsNode) _node.dispose();
      _attachNode();
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    if (_ownsNode) _node.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    if (_focused != _node.hasFocus) setState(() => _focused = _node.hasFocus);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      widget.onLeft?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.handled;
    }
    if (widget.onPressed != null &&
        event is KeyDownEvent &&
        (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter)) {
      widget.onPressed!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final restHeight = widget.height - 8;
    final chip = Focus(
      focusNode: _node,
      onKeyEvent: _onKey,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 150),
        scale: _focused ? 1.1 : 1.0,
        child: SizedBox(
          height: widget.height,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: _focused ? widget.height : restHeight,
              padding: const EdgeInsets.only(left: 18, right: 22),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: Colors.white.withValues(alpha: _focused ? 0.32 : 0.10),
                border: _focused
                    ? Border.all(color: Colors.white, width: 3)
                    : Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                        width: 1.5,
                      ),
                boxShadow: _focused
                    ? const [BoxShadow(color: Color(0x40FFFFFF), blurRadius: 24)]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.accent,
                      boxShadow: [
                        BoxShadow(color: widget.accent, blurRadius: 7),
                      ],
                    ),
                    child: const SizedBox(width: 8, height: 8),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.label,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      color: const Color(0xFFF4F5F7),
                      fontSize: widget.fontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return widget.onPressed == null
        ? chip
        : GestureDetector(onTap: widget.onPressed, child: chip);
  }
}
