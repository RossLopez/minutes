// SPDX-License-Identifier: GPL-3.0-or-later

import MinutesAudio

/// Picks what a recording captures from.
enum RecordingSources {
    static func make(
        options: MicCapture.Options,
        useFakeAudio: Bool,
    ) -> (mic: any AudioCaptureSource, system: any AudioCaptureSource) {
        #if DEBUG
            if useFakeAudio {
                return (FakeAudioSource(frequency: 300), FakeAudioSource(frequency: 500))
            }
        #endif
        return (MicCapture(options: options), SystemAudioTap())
    }

    /// The name recorded in `meeting.json`. Voice processing always uses the default input.
    static func inputDeviceName(for options: MicCapture.Options) -> String? {
        if !options.voiceProcessing, let uid = options.deviceUID,
           let device = AudioDevices.inputDevices().first(where: { $0.uid == uid })
        {
            return device.name
        }
        return AudioDevices.defaultInputName()
    }
}
