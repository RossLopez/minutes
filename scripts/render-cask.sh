#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fills in packaging/homebrew/minutes.rb for a release, and refuses a zap that could reach the
# user's library.
# Usage: scripts/render-cask.sh <version> <sha256> <output file>
#        scripts/render-cask.sh --check

set -euo pipefail
cd "$(dirname "$0")/.."
template="packaging/homebrew/minutes.rb"

# ~/Minutes holds every recording. A line naming it or one of a library's folders fails here. The
# Application Support folder only holds the pointer to the library, and rmdir only removes it empty.
if grep -vE '^[[:space:]]*#' "$template" | grep -E '~/Minutes|/Minutes/(Models|Meetings|Chats|Templates|\.minutes)'; then
    echo "The cask's zap must never name the Minutes library."
    exit 1
fi
ruby -c "$template" >/dev/null

if [[ "${1:-}" == "--check" ]]; then
    echo "Cask template is fine."
    exit 0
fi

version="${1:?Usage: render-cask.sh <version> <sha256> <output file>}"
sha256="${2:?}"
output="${3:?}"
if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "'$sha256' isn't a SHA-256."
    exit 1
fi
mkdir -p "$(dirname "$output")"
# The tap's copy doesn't need the template's header.
sed -e '1,4d' -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha256/" "$template" >"$output"
ruby -c "$output" >/dev/null
echo "$output"
