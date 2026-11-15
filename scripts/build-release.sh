#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Minutes-<version>-arm64.dmg: archive, export, verify, notarize, DMG, checksum.
# Usage: scripts/build-release.sh <version>
#
# With no signing variables set, the app is ad-hoc signed and nothing is notarized, so anyone can
# build a fork. docs/RELEASING.md describes each variable:
#   DEVELOPER_ID_IDENTITY   "Developer ID Application: Name (TEAMID)", from the keychain
#   APPLE_TEAM_ID           the team of that identity
#   NOTARY_KEY_PATH         App Store Connect API key (.p8) for notarytool
#   NOTARY_KEY_ID, NOTARY_ISSUER
#   SPARKLE_PUBLIC_KEY      overrides Config/Release.xcconfig, for testing updates with a test key
#   UPDATES_OFF=1           builds with no update key, so the app never checks, for builds whose
#                           appcast won't be published, like a fork's
#   BUILD_NUMBER            defaults to the number of commits, which only goes up
#   OUTPUT_DIR              defaults to build/release
#   DMGBUILD                defaults to dmgbuild on the PATH

set -euo pipefail

version="${1:?Usage: build-release.sh <version>, like 0.1.0}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "Version '$version' isn't like 0.1.0 or 0.1.0-rc.1"
    exit 1
fi
cd "$(dirname "$0")/.."

out="${OUTPUT_DIR:-build/release}"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
dmgbuild="${DMGBUILD:-dmgbuild}"
identity="${DEVELOPER_ID_IDENTITY:-}"
archive="$out/Minutes.xcarchive"
app="$out/export/Minutes.app"
dmg="$out/Minutes-$version-arm64.dmg"

notarizes=false
if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    if [[ -z "$identity" ]]; then
        echo "Notarizing needs DEVELOPER_ID_IDENTITY too."
        exit 1
    fi
    notarizes=true
fi

rm -rf "$out"
mkdir -p "$out/export"

echo "==> Minutes $version ($build_number), $([[ -n "$identity" ]] && echo "signed by $identity" || echo "ad-hoc signed")"
xcodegen generate

settings=(MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number")
if [[ "${UPDATES_OFF:-}" == 1 ]]; then
    settings+=(SPARKLE_PUBLIC_KEY=)
elif [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    settings+=(SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY")
fi
if [[ -n "$identity" ]]; then
    settings+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="${APPLE_TEAM_ID:?}"
        OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

echo "==> Archiving"
xcodebuild archive \
    -project Minutes.xcodeproj \
    -scheme Minutes \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive" \
    -derivedDataPath build/release-derived \
    "${settings[@]}" | tail -3

echo "==> Exporting"
if [[ -n "$identity" ]]; then
    # A Developer ID export signs everything inside the app from the inside out, with a secure
    # timestamp. Nothing here signs with --deep.
    options="$out/ExportOptions.plist"
    cat >"$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$identity</string>
    <key>teamID</key>
    <string>$APPLE_TEAM_ID</string>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" -exportOptionsPlist "$options" |
        tail -3
else
    ditto "$archive/Products/Applications/Minutes.app" "$app"
fi

echo "==> Verifying"
scripts/verify-bundle.sh "$app" --release
codesign --verify --strict --deep --verbose=1 "$app"
check_version() {
    local key="$1" expected="$2" actual
    actual="$(plutil -extract "$key" raw -o - "$app/Contents/Info.plist")"
    if [[ "$actual" != "$expected" ]]; then
        echo "$key is '$actual', expected '$expected'"
        exit 1
    fi
}
check_version CFBundleShortVersionString "$version"
check_version CFBundleVersion "$build_number"

notarize() {
    local file="$1" result status
    echo "==> Notarizing $(basename "$file")"
    result="$(xcrun notarytool submit "$file" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER" --wait --timeout 1h --output-format json)"
    status="$(plutil -extract status raw -o - - <<<"$result")"
    if [[ "$status" != "Accepted" ]]; then
        echo "Notarization finished as '$status'. The log:"
        xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$result")" --key "$NOTARY_KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" || true
        exit 1
    fi
}

if $notarizes; then
    zip="$out/Minutes-notarize.zip"
    ditto -c -k --keepParent "$app" "$zip"
    notarize "$zip"
    rm "$zip"
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose "$app"
fi

echo "==> Making $(basename "$dmg")"
"$dmgbuild" -s packaging/dmg/settings.py -D app="$app" -D here="$PWD/packaging/dmg" "Minutes $version" "$dmg"

if [[ -n "$identity" ]]; then
    codesign --sign "$identity" --timestamp "$dmg"
fi
if $notarizes; then
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi

(cd "$out" && shasum -a 256 "$(basename "$dmg")" >"$(basename "$dmg").sha256")
echo "==> Done"
echo "$dmg"
cat "$dmg.sha256"
