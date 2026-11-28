#!/usr/bin/env bash
# Lambent's AI upscaler on the Apple TV (Runner/Playback/Lambent/LambentNeuralScaler.swift): builds NVIDIA's VSR low networks and their
# Neural Engine students for Core ML at each of the player's picture sizes (LambentNeuralScaler.sizes) from a Lambent checkout's weights
# (companion/shaders/vsr/build_coreml_player.sh), and puts them, with their licence and notice, in Runner/Shaders/vsr (git-ignored; the
# app and tools/LiftBench bundle the Shaders folder). Built every time (a few seconds): a model left from an older checkout would
# otherwise ship unnoticed.
#
#   tvos/scripts/copy_vsr_models.sh <Lambent checkout>
#
# Without them the Apple TV's ladder starts at the shader upscaler.
set -euo pipefail
lambent="${1:?usage: copy_vsr_models.sh <Lambent checkout>}"
here="$(cd "$(dirname "$0")" && pwd)"
src="$lambent/companion/shaders/vsr"
out="$here/../Runner/Shaders/vsr"
# LambentNeuralScaler.sizes: SD, 720p, a 1080p film wider than 2.3:1, 1080p.
sizes="768x576 1280x736 1920x832 1920x1088"
built="$(mktemp -d)"
trap 'rm -rf "$built"' EXIT
# shellcheck disable=SC2086
"$src/build_coreml_player.sh" "$built" $sizes >/dev/null
rm -rf "$out"
mkdir -p "$out"
cp -R "$built"/*.mlmodelc "$out/"
cp "$src/LICENSE-NVIDIA-Open-Model.pdf" "$src/NOTICE.txt" "$out/"
echo "$out"
ls "$out"
