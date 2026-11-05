// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MinutesAudio
import SwiftUI

struct RecordingSettingsTab: View {
    @AppStorage(RecordingPreferences.voiceProcessingKey) private var voiceProcessing = false
    @AppStorage(RecordingPreferences.inputDeviceUIDKey) private var inputDeviceUID = ""
    @AppStorage(RecordingPreferences.audioFormatKey) private var audioFormat = RecordingAudioFormat.aac.rawValue
    @AppStorage(RecordingPreferences.limitHoursKey) private var limitHours = RecordingPreferences.defaultLimitHours
    @State private var devices: [AudioInputDevice] = []

    private var isSavedDeviceMissing: Bool {
        !inputDeviceUID.isEmpty && !devices.contains { $0.uid == inputDeviceUID }
    }

    private var isRecording: Bool {
        RecordingController.shared.phase != .idle
    }

    var body: some View {
        Form {
            Section {
                Picker("Input device", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if isSavedDeviceMissing {
                        Text("Unavailable Device").tag(inputDeviceUID)
                    }
                }
                .disabled(voiceProcessing)

                Toggle(isOn: $voiceProcessing) {
                    Text("Voice processing")
                    Text(
                        "Reduces echo when you use speakers, but makes meeting audio quieter and always uses the "
                            + "system default microphone. Headphones are better if you have them.",
                    )
                }
            }

            Section {
                Picker("Audio format", selection: $audioFormat) {
                    Text("AAC (smaller files)").tag(RecordingAudioFormat.aac.rawValue)
                    Text("ALAC (lossless)").tag(RecordingAudioFormat.alac.rawValue)
                }
                Stepper(value: $limitHours, in: 1 ... 24) {
                    Text("Warn after \(limitHours) \(limitHours == 1 ? "hour" : "hours")")
                    Text("A warning only. Recordings stop when you stop them.")
                }
            }

            if isRecording {
                Text("Changes apply to your next recording.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            devices = AudioDevices.inputDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            devices = AudioDevices.inputDevices()
        }
    }
}
