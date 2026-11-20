#!/usr/bin/env bash
# Lambent Auto HDR on Android TV (src/main/kotlin/.../LambentAutoHdr.kt): copies the bank of sixteen colour tables (Lambent's
# companion/shaders/lutg: agcm.json, agcm.bin) with its notice and HDRTVNet's licence from a Lambent checkout (or, with `--git <ref>`,
# from that ref of it) into src/main/assets/lambent_autohdr (git-ignored), as tvos/scripts/copy_autohdr_weights.sh does for the Apple
# players. Without them the app makes no Auto HDR and reports none (getLambentCapabilities). Run it before any Play build.
#
#   packages/moonfin_native_video/android/copy_autohdr_weights.sh <Lambent checkout> [--git origin/main]
set -euo pipefail
lambent="${1:?usage: copy_autohdr_weights.sh <Lambent checkout> [--git <ref>]}"
ref="${3:-}"
[ "${2:-}" = "--git" ] || ref=""
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/src/main/assets/lambent_autohdr"
rm -rf "$out"
mkdir -p "$out"
for f in agcm.json agcm.bin NOTICE.txt LICENSE-HDRTVNet.txt; do
  if [ -n "$ref" ]; then
    git -C "$lambent" show "$ref:companion/shaders/lutg/$f" > "$out/$f"
  else
    cp "$lambent/companion/shaders/lutg/$f" "$out/"
  fi
done
ls -l "$out"
