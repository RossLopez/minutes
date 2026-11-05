// SPDX-License-Identifier: GPL-3.0-or-later
//
// Code that runs on real-time audio threads. Nothing here allocates, locks or
// calls into Swift once a ring exists.

#ifndef MinutesAudioRT_h
#define MinutesAudioRT_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A single-producer, single-consumer ring of mono Float32 frames, tagged with
/// the host time of each chunk.
typedef struct MRTRing MRTRing;

typedef struct {
    uint64_t hostTime;
    uint32_t frameCount;
    double sampleRate;
} MRTChunk;

/// Rounds capacityFrames up to a power of two. Call off the audio thread.
MRTRing *_Nonnull mrt_ring_create(uint32_t capacityFrames);
/// Call only after the producer has stopped.
void mrt_ring_destroy(MRTRing *_Nonnull ring);

/// The rate tagged onto chunks from now on. Safe from any thread.
void mrt_ring_set_sample_rate(MRTRing *_Nonnull ring, double sampleRate);

/// Producer side. Copies the first channel of `frames` frames, reading every
/// `stride`th sample. If the ring is full the chunk is dropped and counted, and
/// the host times show the consumer the gap.
bool mrt_ring_write(MRTRing *_Nonnull ring,
                    const float *_Nonnull samples,
                    uint32_t stride,
                    uint32_t frames,
                    uint64_t hostTime) CA_REALTIME_API;

/// Consumer side. Copies the next whole chunk into `destination`. Returns false
/// when the ring is empty. A chunk larger than `capacity` is discarded and
/// counted as dropped, then the call returns the following chunk or false.
bool mrt_ring_read_chunk(MRTRing *_Nonnull ring,
                         MRTChunk *_Nonnull chunk,
                         float *_Nonnull destination,
                         uint32_t capacity);

/// Returns the highest absolute sample since the last call, and resets it.
float mrt_ring_take_peak(MRTRing *_Nonnull ring);

/// Frames lost because the consumer fell behind.
uint64_t mrt_ring_dropped_frames(MRTRing *_Nonnull ring);

/// An AudioDeviceIOProc that writes the first channel of its input to the
/// MRTRing passed as client data.
OSStatus mrt_tap_ioproc(AudioObjectID device,
                        const AudioTimeStamp *_Nonnull now,
                        const AudioBufferList *_Nonnull inputData,
                        const AudioTimeStamp *_Nonnull inputTime,
                        AudioBufferList *_Nonnull outputData,
                        const AudioTimeStamp *_Nonnull outputTime,
                        void *_Nullable clientData);

#ifdef __OBJC__
@class AVAudioSinkNode;
@class AVAudioSourceNode;
@class AVAudioFormat;

/// A sink node that writes the first channel of its input to `ring`.
AVAudioSinkNode *_Nonnull mrt_make_sink_node(MRTRing *_Nonnull ring);

/// A source node playing a steady 1 kHz sine at `amplitude`, for the permission probe.
AVAudioSourceNode *_Nonnull mrt_make_probe_source_node(AVAudioFormat *_Nonnull format, float amplitude);
#endif

#ifdef __cplusplus
}
#endif

#endif /* MinutesAudioRT_h */
