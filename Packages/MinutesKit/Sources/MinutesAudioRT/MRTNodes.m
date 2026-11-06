// SPDX-License-Identifier: GPL-3.0-or-later

#import "MinutesAudioRT.h"

#import <AVFAudio/AVFAudio.h>

#if !__has_feature(objc_arc)
#error "MinutesAudioRT requires ARC"
#endif

AVAudioSinkNode *mrt_make_sink_node(MRTRing *ring) {
    AVAudioSinkNodeReceiverBlockRealtimeSafe block =
        ^OSStatus(const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, const AudioBufferList *inputData) CA_REALTIME_API {
            if (inputData->mNumberBuffers > 0 && inputData->mBuffers[0].mData != NULL) {
                const AudioBuffer *buffer = &inputData->mBuffers[0];
                uint32_t stride = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
                mrt_ring_write(ring, buffer->mData, stride, frameCount, timestamp->mHostTime);
            }
            return noErr;
        };
    return [[AVAudioSinkNode alloc] initWithRealtimeSafeReceiverBlock:block];
}

AVAudioSourceNode *mrt_make_probe_source_node(AVAudioFormat *format, float amplitude) {
    __block double phase = 0;
    double increment = 2.0 * M_PI * 1000.0 / format.sampleRate;
    AVAudioSourceNodeRenderBlockRealtimeSafe block =
        ^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *outputData) CA_REALTIME_API {
            (void)timestamp;
            *isSilence = NO;
            for (UInt32 buffer = 0; buffer < outputData->mNumberBuffers; buffer++) {
                float *samples = outputData->mBuffers[buffer].mData;
                double current = phase;
                for (AVAudioFrameCount frame = 0; frame < frameCount; frame++) {
                    samples[frame] = amplitude * (float)sin(current);
                    current += increment;
                }
                if (buffer + 1 == outputData->mNumberBuffers) {
                    phase = fmod(current, 2.0 * M_PI);
                }
            }
            return noErr;
        };
    return [[AVAudioSourceNode alloc] initWithFormat:format realtimeSafeRenderBlock:block];
}
