// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MinutesAudio

/// `UserDefaults` keys for recording settings, shared by Settings and the recorder.
enum RecordingPreferences {
    static let voiceProcessingKey = "recording.voiceProcessing"
    static let inputDeviceUIDKey = "recording.inputDeviceUID"
    static let audioFormatKey = "recording.audioFormat"
    static let limitHoursKey = "recording.limitHours"
    static let consentNoteShownKey = "consentNoteShown"

    static let defaultLimitHours = 4

    static var voiceProcessing: Bool {
        UserDefaults.standard.bool(forKey: voiceProcessingKey)
    }

    /// Nil means follow the system default input.
    static var inputDeviceUID: String? {
        let uid = UserDefaults.standard.string(forKey: inputDeviceUIDKey) ?? ""
        return uid.isEmpty ? nil : uid
    }

    static var audioFormat: RecordingAudioFormat {
        UserDefaults.standard.string(forKey: audioFormatKey).flatMap(RecordingAudioFormat.init(rawValue:)) ?? .aac
    }

    static var limitSeconds: Double {
        let hours = UserDefaults.standard.object(forKey: limitHoursKey) as? Int ?? defaultLimitHours
        return Double(hours) * 3600
    }
}
