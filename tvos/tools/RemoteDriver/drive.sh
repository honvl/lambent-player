#!/bin/sh
# ./drive.sh <simulator-udid> "<steps>" [out-dir] [launch]
#   steps: up,down:2,select,wait:3,shot:home ... (see UITests/Driver.swift)
# Screenshots land in out-dir (default ./shots). launch=1 relaunches the app first.
#
# DRIVE_STOREKIT=<file.storekit>  runs the app against a local StoreKit test store (see StoreKit/Lambent.storekit), so a
#   purchase completes with no Apple account. Needs DRIVE_APP_PATH too: the simulator build of the app (Runner.app), which
#   becomes the UI test's target app so that the test session applies to the app's bundle id.
set -e
here=$(cd "$(dirname "$0")" && pwd)
udid=$1; steps=$2; out=${3:-$here/shots}; launch=${4:-0}
mkdir -p "$out"
[ -d "$here/RemoteDriver.xcodeproj" ] || (cd "$here" && xcodegen generate -q)
export TEST_RUNNER_DRIVE_STEPS="$steps" TEST_RUNNER_DRIVE_OUT="$out" TEST_RUNNER_DRIVE_LAUNCH="$launch" \
  TEST_RUNNER_DRIVE_STOREKIT="${DRIVE_STOREKIT:-}"
if [ -n "$DRIVE_STOREKIT" ]; then
  [ -n "$DRIVE_APP_PATH" ] || { echo "DRIVE_STOREKIT needs DRIVE_APP_PATH (the built Runner.app)" >&2; exit 1; }
  xcodebuild build-for-testing -project "$here/RemoteDriver.xcodeproj" -scheme RemoteDriverUITests \
    -destination "id=$udid" -derivedDataPath "$here/.build" -quiet 2>&1 | grep -E "error:" || true
  products="$here/.build/Build/Products"
  # The generated test run names the dummy Host app as the app under test; point it at the real one.
  python3 - "$products"/RemoteDriverUITests_*.xctestrun "$products/storekit.xctestrun" "$DRIVE_APP_PATH" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r"(<key>UITargetAppPath</key>\s*<string>)[^<]*", lambda m: m.group(1) + sys.argv[3], s)
open(sys.argv[2], "w").write(s)
PY
  xcodebuild test-without-building -xctestrun "$products/storekit.xctestrun" -destination "id=$udid" 2>&1 \
    | grep -E "error:|Test Case|TEST (EXECUTE|FAILED)" | tail -20
else
  xcodebuild test -project "$here/RemoteDriver.xcodeproj" -scheme RemoteDriverUITests \
    -destination "id=$udid" -derivedDataPath "$here/.build" -quiet 2>&1 | grep -v "^$" | tail -20
fi
