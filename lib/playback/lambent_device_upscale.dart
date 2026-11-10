import 'package:flutter/foundation.dart';

/// What runs on this device right now for the plan's client steps
/// (`LambentEnhancement.clientSteps`): "Auto HDR", "AI upscale" (the Neural
/// Engine), "Shader upscale" or two of them ("Auto HDR · Shader upscale"),
/// from the iPad's and Apple TV's native player (LambentHDRLift.swift's
/// `lambentUpscale` event) or Android's (Media3VideoView.kt's);
/// [lambentDeviceNotNeeded] when the plan asked but
/// nothing was worth doing here; null before it has decided. The player's chip and
/// enhancement panel show it.
final lambentDeviceUpscale = ValueNotifier<String?>(null);

/// The panel's word when the plan asked but nothing runs here (AVPlayer shows
/// the picture); the chip leaves it out. LambentClientUpscale.notNeeded.
const lambentDeviceNotNeeded = 'Not needed';
