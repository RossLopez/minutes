#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs every engine on the meeting and silence files. Warm runs follow cold ones.
#   run-all.sh <work folder>
# The folder needs ami/IS1009c.Mix-Headset.wav and ami/test/*.wav. Results go in results/.

set -u
cd "$(dirname "$0")"
work=$1
tool=.build/release/transcription-spike
meeting=$work/ami/IS1009c.Mix-Headset.wav
results=$work/results
models=$work/models

monitored() {
    python3 -I run-monitored.py "$tool" "$@"
}

for run in 1 2; do
    echo "--- apple $run"
    monitored --engine apple --audio "$meeting" --out "$results/ami-apple-$run.json"
    echo "--- parakeet-v2 $run"
    monitored --engine parakeet --audio "$meeting" --models "$models" --out "$results/ami-parakeet-v2-$run.json"
    echo "--- whisper-vad $run"
    monitored --engine whisper --audio "$meeting" --models "$models" --out "$results/ami-whisper-vad-$run.json"
done

echo "--- whisper-nochunk"
SPIKE_WHISPER_CHUNKING=none monitored --engine whisper --audio "$meeting" --models "$models" \
    --out "$results/ami-whisper-none-1.json"

for run in 1 2; do
    echo "--- parakeet-ultra $run"
    monitored --engine parakeet --model ultra --audio "$meeting" --models "$models" \
        --out "$results/ami-parakeet-ultra-$run.json"
done

for name in digital-silence quiet-noise room-gaps; do
    audio=$work/ami/test/$name.wav
    echo "--- $name"
    "$tool" --engine apple --audio "$audio" --out "$results/silence-$name-apple.json"
    "$tool" --engine parakeet --audio "$audio" --models "$models" --out "$results/silence-$name-parakeet.json"
    "$tool" --engine whisper --audio "$audio" --models "$models" --out "$results/silence-$name-whisper.json"
done

echo ALLDONE
