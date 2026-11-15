#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Signs a release DMG for Sparkle and writes appcast.xml beside it, with that version's notes from
# CHANGELOG.md. The appcast goes on the GitHub release, where SUFeedURL finds the latest one.
# Usage: scripts/make-appcast.sh <dmg> <version> <build number>
#
#   SPARKLE_ED_PRIVATE_KEY  the private key, base64, from Sparkle's generate_keys -x. Without it
#                           nothing is written, so forks still get a DMG.
#   DOWNLOAD_URL            where the DMG will be. Defaults to this version's GitHub release.
#   SPARKLE_BIN             a folder with sign_update. Defaults to downloading Sparkle's tools.

set -euo pipefail

dmg="${1:?Usage: make-appcast.sh <dmg> <version> <build number>}"
version="${2:?}"
build="${3:?}"
cd "$(dirname "$0")/.."

if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    echo "No SPARKLE_ED_PRIVATE_KEY, so no appcast."
    exit 0
fi

sparkle_version="2.10.1"
sparkle_sha256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
bin="${SPARKLE_BIN:-}"
if [[ -z "$bin" ]]; then
    tools="build/sparkle-$sparkle_version"
    if [[ ! -x "$tools/bin/sign_update" ]]; then
        mkdir -p "$tools"
        archive="$tools/Sparkle-$sparkle_version.tar.xz"
        curl -fsSL -o "$archive" \
            "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
        echo "$sparkle_sha256  $archive" | shasum -a 256 -c -
        tar -xf "$archive" -C "$tools" bin
    fi
    bin="$tools/bin"
fi

# Prints: sparkle:edSignature="..." length="..."
key_file="$(mktemp)"
trap 'rm -f "$key_file"' EXIT
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" >"$key_file"
attributes="$("$bin/sign_update" --ed-key-file "$key_file" "$dmg")"
rm -f "$key_file"

url="${DOWNLOAD_URL:-https://github.com/RossLopez/minutes/releases/download/v$version/$(basename "$dmg")}"
notes="$(scripts/changelog-section.sh "$version")"
# A CDATA section can't hold its own end marker.
notes="${notes//]]>/]]&gt;}"
date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
appcast="$(dirname "$dmg")/appcast.xml"

cat >"$appcast" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Minutes</title>
        <link>https://github.com/RossLopez/minutes</link>
        <description>Updates to Minutes.</description>
        <language>en</language>
        <item>
            <title>Minutes $version</title>
            <pubDate>$date</pubDate>
            <sparkle:version>$build</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>https://github.com/RossLopez/minutes/releases</sparkle:fullReleaseNotesLink>
            <description sparkle:format="markdown"><![CDATA[
$notes
]]></description>
            <enclosure url="$url" $attributes type="application/x-apple-diskimage" />
        </item>
    </channel>
</rss>
XML
xmllint --noout "$appcast"
echo "$appcast"
