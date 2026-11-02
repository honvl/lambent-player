import 'package:flutter/foundation.dart';

/// What upscales on this device right now for the plan's client step
/// (`LambentEnhancement.clientUpscaleLines`): "AI upscale" (the Neural
/// Engine) or "Shader upscale", from the iPad's native player
/// (LambentHDRLift.swift's `lambentUpscale` event); null when nothing does.
/// The player's chip and enhancement panel show it.
final lambentDeviceUpscale = ValueNotifier<String?>(null);
