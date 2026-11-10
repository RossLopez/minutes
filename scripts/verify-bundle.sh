#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks that a built Minutes.app matches the spec's platform decisions.
# Usage: scripts/verify-bundle.sh path/to/Minutes.app

set -euo pipefail

app="${1:?Usage: verify-bundle.sh path/to/Minutes.app}"
plist="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/Minutes"
failures=0

check() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "ok    $description: $actual"
    else
        echo "FAIL  $description: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

check_present() {
    local description="$1" actual="$2"
    if [[ -n "$actual" ]]; then
        echo "ok    $description: present"
    else
        echo "FAIL  $description: missing or empty"
        failures=$((failures + 1))
    fi
}

plist_value() {
    plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true
}

check "architectures" "arm64" "$(lipo -archs "$binary")"
check "bundle ID" "io.github.rosslopez.minutes" "$(plist_value CFBundleIdentifier)"
check "minimum macOS" "27.0" "$(plist_value LSMinimumSystemVersion)"
check_present "NSMicrophoneUsageDescription" "$(plist_value NSMicrophoneUsageDescription)"
check_present "NSAudioCaptureUsageDescription" "$(plist_value NSAudioCaptureUsageDescription)"

if [[ -f "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]; then
    echo "ok    third-party notices: present"
else
    echo "FAIL  third-party notices: missing"
    failures=$((failures + 1))
fi

llama="$app/Contents/Frameworks/llama.framework"
if [[ -d "$llama" ]] && codesign --verify --strict "$llama" 2>/dev/null; then
    echo "ok    llama.framework: present and signed"
else
    echo "FAIL  llama.framework: missing or unsigned"
    failures=$((failures + 1))
fi
check "llama.framework has arm64" "yes" "$(lipo -archs "$llama/llama" 2>/dev/null | grep -qw arm64 && echo yes || echo no)"

# Debug builds can swap in fake engines for UI tests. Release builds must not contain them.
if [[ "$app" == *"/Release/"* ]]; then
    if strings -a "$binary" | grep -qE 'MINUTES_FAKE_(TRANSCRIPTION|DIARIZATION|LLM)'; then
        echo "FAIL  fake engines: present in a Release build"
        failures=$((failures + 1))
    else
        echo "ok    fake engines: absent"
    fi
fi

signature="$(codesign -dv "$app" 2>&1)"
if grep -Eq 'flags=.*runtime' <<<"$signature"; then
    echo "ok    hardened runtime: on"
else
    echo "FAIL  hardened runtime: off"
    failures=$((failures + 1))
fi

entitlements="$(mktemp)"
trap 'rm -f "$entitlements"' EXIT
codesign -d --entitlements - --xml "$app" 2>/dev/null >"$entitlements"
# PlistBuddy, because plutil -extract treats the dots in entitlement names as a key path.
entitlement_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$entitlements" 2>/dev/null || true
}

check "audio-input entitlement" "true" "$(entitlement_value com.apple.security.device.audio-input)"
check "app sandbox entitlement" "" "$(entitlement_value com.apple.security.app-sandbox)"

if ((failures > 0)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "All bundle checks passed"
