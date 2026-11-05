// SPDX-License-Identifier: GPL-3.0-or-later

#include "MinutesAudioRT.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define MRT_CHUNK_CAPACITY 8192u

struct MRTRing {
    float *samples;
    uint32_t mask;
    MRTChunk chunks[MRT_CHUNK_CAPACITY];
    _Atomic uint64_t sampleWrite;
    _Atomic uint64_t sampleRead;
    _Atomic uint64_t chunkWrite;
    _Atomic uint64_t chunkRead;
    _Atomic uint64_t dropped;
    _Atomic uint32_t peakBits;
    _Atomic uint64_t sampleRateBits;
    _Atomic int64_t timeOffsetNanos;
};

static uint32_t round_up_power_of_two(uint32_t value) {
    uint32_t result = 1;
    while (result < value && result < (1u << 30)) {
        result <<= 1;
    }
    return result;
}

MRTRing *mrt_ring_create(uint32_t capacityFrames) {
    MRTRing *ring = calloc(1, sizeof(MRTRing));
    uint32_t capacity = round_up_power_of_two(capacityFrames);
    ring->samples = calloc(capacity, sizeof(float));
    ring->mask = capacity - 1;
    return ring;
}

void mrt_ring_destroy(MRTRing *ring) {
    free(ring->samples);
    free(ring);
}

void mrt_ring_set_sample_rate(MRTRing *ring, double sampleRate) {
    uint64_t bits;
    memcpy(&bits, &sampleRate, sizeof(bits));
    atomic_store_explicit(&ring->sampleRateBits, bits, memory_order_relaxed);
}

void mrt_ring_set_time_offset(MRTRing *ring, int64_t nanos) {
    atomic_store_explicit(&ring->timeOffsetNanos, nanos, memory_order_relaxed);
}

bool mrt_ring_write(MRTRing *ring, const float *samples, uint32_t stride, uint32_t frames, uint64_t hostTime) CA_REALTIME_API {
    if (frames == 0) {
        return true;
    }

    uint64_t sampleWrite = atomic_load_explicit(&ring->sampleWrite, memory_order_relaxed);
    uint64_t sampleRead = atomic_load_explicit(&ring->sampleRead, memory_order_acquire);
    uint64_t chunkWrite = atomic_load_explicit(&ring->chunkWrite, memory_order_relaxed);
    uint64_t chunkRead = atomic_load_explicit(&ring->chunkRead, memory_order_acquire);
    uint64_t capacity = (uint64_t)ring->mask + 1;

    if (capacity - (sampleWrite - sampleRead) < frames || chunkWrite - chunkRead >= MRT_CHUNK_CAPACITY) {
        atomic_fetch_add_explicit(&ring->dropped, frames, memory_order_relaxed);
        return false;
    }

    float peak = 0;
    for (uint32_t frame = 0; frame < frames; frame++) {
        float value = samples[frame * stride];
        ring->samples[(sampleWrite + frame) & ring->mask] = value;
        float magnitude = value < 0 ? -value : value;
        if (magnitude > peak) {
            peak = magnitude;
        }
    }

    uint32_t currentBits = atomic_load_explicit(&ring->peakBits, memory_order_relaxed);
    for (;;) {
        float current;
        memcpy(&current, &currentBits, sizeof(current));
        if (peak <= current) {
            break;
        }
        uint32_t peakBits;
        memcpy(&peakBits, &peak, sizeof(peakBits));
        if (atomic_compare_exchange_weak_explicit(&ring->peakBits, &currentBits, peakBits, memory_order_relaxed, memory_order_relaxed)) {
            break;
        }
    }

    uint64_t rateBits = atomic_load_explicit(&ring->sampleRateBits, memory_order_relaxed);
    double rate;
    memcpy(&rate, &rateBits, sizeof(rate));
    ring->chunks[chunkWrite & (MRT_CHUNK_CAPACITY - 1)] = (MRTChunk){
        .hostTime = hostTime,
        .frameCount = frames,
        .sampleRate = rate,
        .timeOffsetNanos = atomic_load_explicit(&ring->timeOffsetNanos, memory_order_relaxed),
    };

    atomic_store_explicit(&ring->sampleWrite, sampleWrite + frames, memory_order_release);
    atomic_store_explicit(&ring->chunkWrite, chunkWrite + 1, memory_order_release);
    return true;
}

bool mrt_ring_read_chunk(MRTRing *ring, MRTChunk *chunk, float *destination, uint32_t capacity) {
    for (;;) {
        uint64_t chunkRead = atomic_load_explicit(&ring->chunkRead, memory_order_relaxed);
        uint64_t chunkWrite = atomic_load_explicit(&ring->chunkWrite, memory_order_acquire);
        if (chunkRead == chunkWrite) {
            return false;
        }

        MRTChunk next = ring->chunks[chunkRead & (MRT_CHUNK_CAPACITY - 1)];
        uint64_t sampleRead = atomic_load_explicit(&ring->sampleRead, memory_order_relaxed);

        bool fits = next.frameCount <= capacity;
        if (fits) {
            for (uint32_t frame = 0; frame < next.frameCount; frame++) {
                destination[frame] = ring->samples[(sampleRead + frame) & ring->mask];
            }
            *chunk = next;
        } else {
            atomic_fetch_add_explicit(&ring->dropped, next.frameCount, memory_order_relaxed);
        }

        atomic_store_explicit(&ring->sampleRead, sampleRead + next.frameCount, memory_order_release);
        atomic_store_explicit(&ring->chunkRead, chunkRead + 1, memory_order_release);
        if (fits) {
            return true;
        }
    }
}

float mrt_ring_take_peak(MRTRing *ring) {
    uint32_t bits = atomic_exchange_explicit(&ring->peakBits, 0, memory_order_relaxed);
    float peak;
    memcpy(&peak, &bits, sizeof(peak));
    return peak;
}

uint64_t mrt_ring_dropped_frames(MRTRing *ring) {
    return atomic_load_explicit(&ring->dropped, memory_order_relaxed);
}

OSStatus mrt_tap_ioproc(AudioObjectID device,
                        const AudioTimeStamp *now,
                        const AudioBufferList *inputData,
                        const AudioTimeStamp *inputTime,
                        AudioBufferList *outputData,
                        const AudioTimeStamp *outputTime,
                        void *clientData) {
    (void)device;
    (void)now;
    (void)outputData;
    (void)outputTime;

    if (clientData == NULL || inputData->mNumberBuffers == 0) {
        return noErr;
    }
    const AudioBuffer *buffer = &inputData->mBuffers[0];
    if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
        return noErr;
    }

    uint32_t channels = buffer->mNumberChannels;
    uint32_t frames = buffer->mDataByteSize / (uint32_t)sizeof(float) / channels;
    mrt_ring_write(clientData, buffer->mData, channels, frames, inputTime->mHostTime);
    return noErr;
}
