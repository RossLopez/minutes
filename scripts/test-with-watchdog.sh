#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the package tests, and if they take longer than the limit, prints where every thread of the
# test process is stuck before failing. A hang on CI then says why instead of running for hours.
# Usage: scripts/test-with-watchdog.sh [limit in minutes, default 15]

set -uo pipefail

limit_minutes="${1:-15}"
deadline=$((SECONDS + limit_minutes * 60))

swift test --package-path Packages/MinutesKit &
tests=$!

while sleep 10 && kill -0 "$tests" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
        echo "::error::Unit tests still running after $limit_minutes minutes. Sampling the test process."
        # Each test target runs in a swiftpm-testing-helper child. Its stacks show what's stuck.
        for pid in $(pgrep -f swiftpm-testing-helper); do
            sample "$pid" 5 -mayDie 2>&1
        done
        pkill -f swiftpm-testing-helper
        kill "$tests" 2>/dev/null
        exit 1
    fi
done

wait "$tests"
