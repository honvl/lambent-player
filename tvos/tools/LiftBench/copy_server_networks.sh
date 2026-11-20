#!/usr/bin/env bash
# The Mac server's own network code and weights, for the Apple TV benchmark (Sources/ServerBench.swift): Lambent Server's AI upscaler at
# every tier (live-enhancer-mac's NeuralScaler.swift, on the Neural Engine and, on an A19 or M5, through Metal 4's tensor ops in
# TensorNet.swift) and its Auto HDR networks (Agcm.swift: the bank of sixteen tables, `lutg`, and the spatial-aware tables + U-Net,
# `salutu`), so the timings compare one for one with a Mac's `--lift-bench`. Copies into Server/ and ServerShaders/ (both git-ignored):
#   - Server/*.swift from <Lambent checkout> at <ref> (default origin/main);
#   - ServerShaders/vsr: every network's Core ML model at 1920x1088 (built in the checkout's companion/shaders/metal/vsr by
#     companion/shaders/vsr/build_coreml.sh, run first when one is missing) and its weights (.json, .bin) for the tensor path;
#   - ServerShaders/lutg and ServerShaders/salutu at <ref>.
#
#   tvos/tools/LiftBench/copy_server_networks.sh <Lambent checkout> [<ref>]
set -euo pipefail
lambent="${1:?usage: copy_server_networks.sh <Lambent checkout> [<ref>]}"
ref="${2:-origin/main}"
here="$(cd "$(dirname "$0")" && pwd)"
src=companion/live-enhancer-mac/Sources/LambentLiveEnhancer
rm -rf "$here/Server" "$here/ServerShaders"
mkdir -p "$here/Server" "$here/ServerShaders/vsr" "$here/ServerShaders/lutg" "$here/ServerShaders/salutu"
# Log.swift and Bench.swift stay on the Mac: ServerShims.swift stands in for the little of them these use.
for f in NeuralScaler TensorNet Agcm ToneParams ShaderScaler; do
  git -C "$lambent" show "$ref:$src/$f.swift" > "$here/Server/$f.swift"
done
# The one macOS-only call (the HDR override file under the home folder): the app's own home on tvOS and iOS.
sed -i '' 's/FileManager\.default\.homeDirectoryForCurrentUser/URL(fileURLWithPath: NSHomeDirectory())/g' "$here"/Server/*.swift
networks="neural-low neural-hb neural-medium neural-hb-medium neural-high neural-hb-high neural-low-student neural-hb-student"
built="$lambent/companion/shaders/metal/vsr"
for net in $networks; do
  if [ ! -d "$built/$net-1920x1088.mlmodelc" ]; then "$lambent/companion/shaders/vsr/build_coreml.sh" "$built"; fi
  cp -R "$built/$net-1920x1088.mlmodelc" "$here/ServerShaders/vsr/"
  for ext in json bin; do git -C "$lambent" show "$ref:companion/shaders/vsr/$net.$ext" > "$here/ServerShaders/vsr/$net.$ext"; done
done
for f in LICENSE-NVIDIA-Open-Model.pdf NOTICE.txt; do git -C "$lambent" show "$ref:companion/shaders/vsr/$f" > "$here/ServerShaders/vsr/$f"; done
for folder in lutg salutu; do
  for f in agcm.json agcm.bin NOTICE.txt; do git -C "$lambent" show "$ref:companion/shaders/$folder/$f" > "$here/ServerShaders/$folder/$f"; done
done
# The server's shaderDirectory() looks for this file to know the folder.
git -C "$lambent" show "$ref:companion/shaders/metal/ravu-lite-ar-r3.json" > "$here/ServerShaders/ravu-lite-ar-r3.json" 2>/dev/null || touch "$here/ServerShaders/ravu-lite-ar-r3.json"
echo "server networks from $(git -C "$lambent" rev-parse --short "$ref"): $(ls "$here/Server" | tr '\n' ' ')"
du -sh "$here/ServerShaders"
