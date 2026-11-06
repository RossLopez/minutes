// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import AVFoundation
import MinutesAudio
import Observation
import UserNotifications

enum PermissionStatus: Equatable {
    case granted
    case notRequested
    case denied
    case unknown
    case checking
}

/// The live state of the three permissions Minutes uses.
@MainActor @Observable
final class PermissionsModel {
    static let shared = PermissionsModel()

    /// Probing starts a real tap, which could show the system's prompt. So nothing probes until
    /// the user has pressed Request or Record once.
    private static let systemAudioRequestedKey = "permissions.systemAudioRequested"

    private(set) var microphone = PermissionStatus.notRequested
    private(set) var systemAudio = PermissionStatus.notRequested
    private(set) var notifications = PermissionStatus.notRequested

    private init() {
        refreshMicrophone()
    }

    /// Re-checks whatever is cheap, plus system audio when it's been asked for and nothing is recording.
    func refresh(includingSystemAudio: Bool) async {
        refreshMicrophone()
        await refreshNotifications()
        if includingSystemAudio,
           UserDefaults.standard.bool(forKey: Self.systemAudioRequestedKey),
           !RecordingController.shared.isRecording
        {
            _ = await checkSystemAudio()
        }
    }

    func requestMicrophoneIfNeeded() async -> PermissionStatus {
        refreshMicrophone()
        if microphone == .notRequested {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshMicrophone()
        }
        return microphone
    }

    /// The first call can show the system prompt, and returns once it's answered.
    func checkSystemAudio() async -> PermissionStatus {
        UserDefaults.standard.set(true, forKey: Self.systemAudioRequestedKey)
        systemAudio = .checking
        let result: PermissionStatus = switch await SystemAudioPermissionProbe.run() {
        case .granted: .granted
        case .denied: .denied
        case .unknown: .unknown
        }
        systemAudio = result
        return result
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshNotifications()
    }

    func openSystemSettings(_ pane: SystemSettingsPane) {
        if let url = pane.url, NSWorkspace.shared.open(url) {
            return
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(fallback)
        }
    }

    private func refreshMicrophone() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notRequested
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
    }

    private func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .notDetermined: .notRequested
        case .denied: .denied
        @unknown default: .unknown
        }
    }
}

enum SystemSettingsPane {
    case microphone
    case systemAudio
    case notifications

    var url: URL? {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")
        case .systemAudio:
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture")
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
    }
}
