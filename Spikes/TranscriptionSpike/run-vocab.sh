#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs every engine on the read-aloud recording, with vocabulary biasing off and on.
#   run-vocab.sh <work folder> <mic file> <terms file>

set -u
cd "$(dirname "$0")"
work=$1
audio=$2
terms=$3
tool=.build/release/transcription-spike
results=$work/results
models=$work/models

"$tool" --engine apple --audio "$audio" --out "$results/vocab-apple-off.json"
"$tool" --engine apple --audio "$audio" --terms "$terms" --out "$results/vocab-apple-on.json"
"$tool" --engine apple --model dictation --audio "$audio" --out "$results/vocab-dictation-off.json"
"$tool" --engine apple --model dictation --audio "$audio" --terms "$terms" --out "$results/vocab-dictation-on.json"
for model in v2 ultra; do
    "$tool" --engine parakeet --model "$model" --audio "$audio" --models "$models" \
        --out "$results/vocab-parakeet-$model-off.json"
    CFFIXED_USER_HOME=$work/home "$tool" --engine parakeet --model "$model" --audio "$audio" --models "$models" --terms "$terms" \
        --out "$results/vocab-parakeet-$model-on.json"
done
"$tool" --engine whisper --audio "$audio" --models "$models" --out "$results/vocab-whisper-off.json"
"$tool" --engine whisper --audio "$audio" --models "$models" --terms "$terms" \
    --out "$results/vocab-whisper-on.json"
