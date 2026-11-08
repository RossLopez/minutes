#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Runs a command and reports which processes' memory grew while it ran.

Core ML and the Speech framework do much of their work in system services, so a process's own
footprint can miss most of the real cost. This samples every process's resident size once a second.

  run-monitored.py <command...>
"""

import subprocess
import sys
import time


def snapshot():
    output = subprocess.run(["ps", "-axo", "pid=,rss=,comm="], capture_output=True, text=True).stdout
    sizes = {}
    for line in output.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            sizes[(parts[0], parts[2].rsplit("/", 1)[-1])] = int(parts[1])
    return sizes


baseline = snapshot()
peaks = {}
process = subprocess.Popen(sys.argv[1:])
while process.poll() is None:
    now = snapshot()
    total = 0
    for key, size in now.items():
        peaks[key] = max(peaks.get(key, 0), size)
    time.sleep(1)

grown = sorted(
    ((peak - baseline.get(key, 0), peak, key[1]) for key, peak in peaks.items()),
    reverse=True,
)
print("  memory growth while running:")
for growth, peak, name in grown[:5]:
    if growth > 20 * 1024:
        print(f"    {name}: +{growth / 1024:.0f} MB (peak {peak / 1024:.0f} MB)")
sys.exit(process.returncode)
