#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stricter vocabulary settings, vocabulary over a meeting that never says the terms, and four hours.
#   run-round2.sh <work folder> <mic file> <terms file>

set -u
cd "$(dirname "$0")"
work=$1
audio=$2
terms=$3
tool=.build/release/transcription-spike
meeting=$work/ami/IS1009c.Mix-Headset.wav
long=$work/ami/test/four-hours.m4a
results=$work/results
models=$work/models
export CFFIXED_USER_HOME=$work/home

monitored() {
    python3 -I run-monitored.py "$tool" "$@"
}

echo "--- stricter thresholds on the script"
for model in v2 ultra; do
    SPIKE_CBW=0 SPIKE_MINSIM=0.7 "$tool" --engine parakeet --model "$model" --audio "$audio" --models "$models" \
        --terms "$terms" --out "$results/vocab-parakeet-$model-strict.json"
    SPIKE_CBW=2 SPIKE_MINSIM=0.6 "$tool" --engine parakeet --model "$model" --audio "$audio" --models "$models" \
        --terms "$terms" --out "$results/vocab-parakeet-$model-mid.json"
done
SPIKE_WHISPER_CHUNKING=none "$tool" --engine whisper --audio "$audio" --models "$models" \
    --out "$results/vocab-whisper-none-off.json"

echo "--- vocabulary on a meeting that never says the terms"
for model in v2 ultra; do
    "$tool" --engine parakeet --model "$model" --audio "$meeting" --models "$models" --terms "$terms" \
        --out "$results/absent-parakeet-$model-default.json"
    SPIKE_CBW=2 SPIKE_MINSIM=0.6 "$tool" --engine parakeet --model "$model" --audio "$meeting" --models "$models" \
        --terms "$terms" --out "$results/absent-parakeet-$model-mid.json"
    SPIKE_CBW=0 SPIKE_MINSIM=0.7 "$tool" --engine parakeet --model "$model" --audio "$meeting" --models "$models" \
        --terms "$terms" --out "$results/absent-parakeet-$model-strict.json"
done

echo "--- four hours"
echo "apple"; monitored --engine apple --audio "$long" --out "$results/long-apple.json"
echo "parakeet v2"; monitored --engine parakeet --audio "$long" --models "$models" --out "$results/long-parakeet-v2.json"
echo "parakeet ultra"; monitored --engine parakeet --model ultra --audio "$long" --models "$models" --out "$results/long-parakeet-ultra.json"
echo "parakeet ultra with vocabulary"; SPIKE_CBW=2 SPIKE_MINSIM=0.6 monitored --engine parakeet --model ultra --audio "$long" --models "$models" --terms "$terms" --out "$results/long-parakeet-ultra-vocab.json"
echo "whisper, no chunking"; SPIKE_WHISPER_CHUNKING=none monitored --engine whisper --audio "$long" --models "$models" --out "$results/long-whisper-none.json"
echo ALLDONE
