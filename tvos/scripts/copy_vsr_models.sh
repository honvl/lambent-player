#!/usr/bin/env bash
# Lambent's AI upscaler on the Apple TV (Runner/Playback/Lambent/LambentNeuralScaler.swift): copies NVIDIA's VSR low networks, compiled
# for Core ML at 1920 x 1088, with their licence and notice, from a Lambent checkout into Runner/Shaders/vsr (git-ignored; the app and
# tools/LiftBench bundle the Shaders folder). Builds them there first with companion/shaders/vsr/build_coreml.sh when they are missing.
#
#   tvos/scripts/copy_vsr_models.sh <Lambent checkout>
#
# Without them the Apple TV's ladder starts at the shader upscaler.
set -euo pipefail
lambent="${1:?usage: copy_vsr_models.sh <Lambent checkout>}"
here="$(cd "$(dirname "$0")" && pwd)"
src="$lambent/companion/shaders/vsr"
built="$lambent/companion/shaders/metal/vsr"
out="$here/../Runner/Shaders/vsr"
if [ ! -d "$built/neural-low-1920x1088.mlmodelc" ] || [ ! -d "$built/neural-hb-1920x1088.mlmodelc" ]; then
  "$src/build_coreml.sh" "$built"
fi
rm -rf "$out"
mkdir -p "$out"
for net in neural-low neural-hb; do
  cp -R "$built/$net-1920x1088.mlmodelc" "$out/"
done
cp "$src/LICENSE-NVIDIA-Open-Model.pdf" "$src/NOTICE.txt" "$out/"
echo "$out"
ls "$out"
