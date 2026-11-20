import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What this device can run of Lambent Enhance by itself (ENTITLEMENTS.md
/// section 8.4), as its native player reports it.
@immutable
class LambentDeviceCapabilities {
  const LambentDeviceCapabilities({
    required this.ai,
    required this.shader,
    required this.hdr,
  });

  static const none = LambentDeviceCapabilities(
    ai: false,
    shader: false,
    hdr: false,
  );

  final bool ai;
  final bool shader;
  final bool hdr;

  /// What a licence adds here. Shaders alone are not worth paying for.
  bool get worthBuying => ai || hdr;

  /// What the purchase screen promises: "AI upscaling and HDR".
  String get summary {
    final upscale = ai
        ? 'AI upscaling'
        : shader
        ? 'shader upscaling'
        : null;
    return [?upscale, if (hdr) 'HDR'].join(' and ');
  }

  factory LambentDeviceCapabilities.fromMap(Map<dynamic, dynamic>? map) =>
      LambentDeviceCapabilities(
        ai: map?['ai'] == true,
        shader: map?['shader'] == true,
        hdr: map?['hdr'] == true,
      );

  static const _control = MethodChannel('moonfin/ios_aether_control');

  /// Android's player (Media3Bridge.kt): RAVU-lite, and Lambent Auto HDR
  /// where this device's own benchmark says the bank of tables keeps up.
  static const _media3 = MethodChannel('moonfin/media3_video_control');

  /// Nothing on a platform whose player has no such steps yet.
  static Future<LambentDeviceCapabilities> detect() async {
    try {
      return LambentDeviceCapabilities.fromMap(
        await (defaultTargetPlatform == TargetPlatform.android && !kIsWeb
                ? _media3
                : _control)
            .invokeMethod<Map<dynamic, dynamic>>('getLambentCapabilities'),
      );
    } on MissingPluginException {
      return none;
    } on PlatformException {
      return none;
    }
  }
}
