#!/bin/sh
# ./drive.sh <simulator-udid> "<steps>" [out-dir] [launch]
#   steps: up,down:2,select,wait:3,shot:home ... (see UITests/Driver.swift)
# Screenshots land in out-dir (default ./shots). launch=1 relaunches the app first.
set -e
here=$(cd "$(dirname "$0")" && pwd)
udid=$1; steps=$2; out=${3:-$here/shots}; launch=${4:-0}
mkdir -p "$out"
[ -d "$here/RemoteDriver.xcodeproj" ] || (cd "$here" && xcodegen generate -q)
TEST_RUNNER_DRIVE_STEPS="$steps" TEST_RUNNER_DRIVE_OUT="$out" TEST_RUNNER_DRIVE_LAUNCH="$launch" \
  xcodebuild test -project "$here/RemoteDriver.xcodeproj" -scheme RemoteDriverUITests \
    -destination "id=$udid" -derivedDataPath "$here/.build" -quiet 2>&1 | grep -v "^$" | tail -20
