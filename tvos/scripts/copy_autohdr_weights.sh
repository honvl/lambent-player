#!/usr/bin/env bash
# Lambent Auto HDR on Apple TV, iPhone, iPad and Mac (Runner/Playback/Lambent/LambentAutoHDR.swift): copies the bank of sixteen colour
# tables (Lambent's companion/shaders/lutg: agcm.json, agcm.bin), with its notice and HDRTVNet's licence, from a Lambent checkout (or, with
# `--git <ref>`, from that ref of it) into Runner/Shaders/autohdr (git-ignored; the apps bundle the Shaders folder). Without them the device
# has no Auto HDR and reports none (getLambentCapabilities).
#
#   tvos/scripts/copy_autohdr_weights.sh <Lambent checkout> [--git origin/main]
set -euo pipefail
lambent="${1:?usage: copy_autohdr_weights.sh <Lambent checkout> [--git <ref>]}"
ref="${3:-}"
[ "${2:-}" = "--git" ] || ref=""
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../Runner/Shaders/autohdr"
rm -rf "$out"
mkdir -p "$out"
for f in agcm.json agcm.bin NOTICE.txt LICENSE-HDRTVNet.txt; do
  if [ -n "$ref" ]; then
    git -C "$lambent" show "$ref:companion/shaders/lutg/$f" > "$out/$f"
  else
    cp "$lambent/companion/shaders/lutg/$f" "$out/"
  fi
done
echo "$out"
ls -l "$out"
