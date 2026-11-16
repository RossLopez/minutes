#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Records the demo video's scenes as separate .mov files, one per scene, plus a JSON file each with
# the clicks and typing in it, for adding a cursor in a video editor. DemoVideoUITests plays the
# scenes in the app's demo mode, with the made-up meeting in App/Demo/DemoContent.swift, and this
# script records the app's window while each one plays.
#
# Usage: scripts/record-demo.sh [output folder, default build/demo-video]
#
# Needs Screen Recording permission for whatever runs it (System Settings › Privacy & Security ›
# Screen & System Audio Recording), and the screen to itself for about three minutes.

set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-build/demo-video}"
rm -rf "${out:?}"
mkdir -p "$out"
log="$out/xcodebuild.log"

# Check for permission first: without it, screencapture can't make even a still.
if ! screencapture -x -R0,0,8,8 "$out/permission-check.png" 2>/dev/null; then
    echo "Screen recording isn't allowed. Turn it on for this app in System Settings › Privacy & Security ›"
    echo "Screen & System Audio Recording, then run this again."
    exit 1
fi
rm -f "$out/permission-check.png"

xcodegen generate

# The one folder outside its sandbox the test runner may write to (MinutesUITests.entitlements).
signals="/private/tmp/MinutesDemoVideo"
rm -rf "${signals:?}"
mkdir -p "$signals"

# The UI tests share the app's settings, and demo mode resizes the window, so put back the size it
# had.
frame_key="NSWindow Frame main"
saved_frame="$(defaults read io.github.rosslopez.minutes "$frame_key" 2>/dev/null || true)"
capture_pid=""
test_pid=""
finish() {
    [[ -n "$capture_pid" ]] && kill -INT "$capture_pid" 2>/dev/null || true
    [[ -n "$test_pid" ]] && kill "$test_pid" 2>/dev/null || true
    if [[ -n "$saved_frame" ]]; then
        defaults write io.github.rosslopez.minutes "$frame_key" "$saved_frame"
    fi
}
trap finish EXIT

echo "==> Building and starting the demo (the screen is in use until it's done)"
# xcodebuild passes TEST_RUNNER_ variables to the test runner without the prefix.
TEST_RUNNER_MINUTES_DEMO_VIDEO=1 xcodebuild test \
    -project Minutes.xcodeproj \
    -scheme Minutes \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build \
    -only-testing:MinutesUITests/DemoVideoUITests >"$log" 2>&1 &
test_pid=$!

# Each scene: the test writes <scene>.start with the window's frame, waits for <scene>.go, plays,
# writes <scene>.events.json and <scene>.stop, then waits for <scene>.done.
recorded=()
while kill -0 "$test_pid" 2>/dev/null; do
    start="$(find "$signals" -maxdepth 1 -name '*.start' 2>/dev/null | sort | head -1 || true)"
    if [[ -z "$start" ]]; then
        sleep 0.2
        continue
    fi
    scene="$(basename "$start" .start)"
    rect="$(python3 -I -c 'import json, sys; f = json.load(open(sys.argv[1]))
print(",".join(str(round(f[k])) for k in ("x", "y", "width", "height")))' "$start")"
    rm "$start"
    echo "==> Recording $scene"
    screencapture -v -x -R"$rect" "$out/$scene.mov" &
    capture_pid=$!
    sleep 1.5
    touch "$signals/$scene.go"
    while [[ ! -f "$signals/$scene.stop" ]] && kill -0 "$test_pid" 2>/dev/null; do
        sleep 0.1
    done
    kill -INT "$capture_pid" 2>/dev/null || true
    wait "$capture_pid" || true
    capture_pid=""
    cp "$signals/$scene.events.json" "$out/$scene.json" 2>/dev/null || true
    touch "$signals/$scene.done"
    recorded+=("$scene")
done

if wait "$test_pid"; then
    status=0
else
    status=$?
fi
test_pid=""
tail -5 "$log"
echo "==> ${#recorded[@]} scenes in $out"
ls -1 "$out"
exit "$status"
