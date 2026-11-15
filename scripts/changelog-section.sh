#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prints one version's section of CHANGELOG.md, without its heading. Fails when there's none, so a
# release can't go out without notes.
# Usage: scripts/changelog-section.sh <version>

set -euo pipefail

version="${1:?Usage: changelog-section.sh <version>}"
cd "$(dirname "$0")/.."

section="$(awk -v version="$version" '
    /^## \[/ {
        if (found) exit
        if (index($0, "## [" version "]") == 1) { found = 1; next }
    }
    found { print }
' CHANGELOG.md)"

# Drop blank lines at either end.
section="$(sed -e '/./,$!d' <<<"$section" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
if [[ -z "$section" ]]; then
    echo "CHANGELOG.md has no section for $version." >&2
    exit 1
fi
printf '%s\n' "$section"
