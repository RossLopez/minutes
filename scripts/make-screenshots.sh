#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Takes the README's screenshots of the made-up demo library, in light and dark, and saves them to
# docs/screenshots/. They come from ScreenshotUITests, which needs the screen to itself while it runs.
# Usage: scripts/make-screenshots.sh

set -euo pipefail
cd "$(dirname "$0")/.."

result="build/screenshots.xcresult"
export_dir="build/screenshots"
rm -rf "$result" "$export_dir"
mkdir -p "$export_dir" docs/screenshots

xcodegen generate

# The UI tests share the app's settings, and screenshot mode resizes the window, so put back the
# size it had.
frame_key="NSWindow Frame main"
saved_frame="$(defaults read io.github.rosslopez.minutes "$frame_key" 2>/dev/null || true)"
restore_frame() {
    if [[ -n "$saved_frame" ]]; then
        defaults write io.github.rosslopez.minutes "$frame_key" "$saved_frame"
    fi
}
trap restore_frame EXIT

# xcodebuild passes TEST_RUNNER_ variables to the test runner without the prefix.
TEST_RUNNER_MINUTES_SCREENSHOTS=1 xcodebuild test \
    -project Minutes.xcodeproj \
    -scheme Minutes \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build \
    -resultBundlePath "$result" \
    -only-testing:MinutesUITests/ScreenshotUITests | tail -5

xcrun xcresulttool export attachments --path "$result" --output-path "$export_dir" >/dev/null

# The manifest maps each exported file to the name the test gave it, like "summary-light_0_….png".
python3 -I - "$export_dir" <<'PY'
import json, pathlib, re, shutil, sys
folder = pathlib.Path(sys.argv[1])
for test in json.loads((folder / "manifest.json").read_text()):
    for attachment in test["attachments"]:
        name = re.sub(r"_\d+_[0-9A-F-]+\.png$", "", attachment["suggestedHumanReadableName"])
        shutil.copy(folder / attachment["exportedFileName"], pathlib.Path("docs/screenshots") / f"{name}.png")
        print(f"docs/screenshots/{name}.png")
PY
