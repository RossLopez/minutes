// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let controller = RecordingController.shared

    var body: some View {
        Button(controller.isRecording ? "Stop Recording" : "Start Recording") {
            controller.toggle()
        }
        .disabled(!controller.canToggle)

        if controller.isRecording {
            let elapsed = Duration.seconds(controller.elapsedSeconds).formatted(.time(pattern: .hourMinuteSecond))
            Text("Recording: \(elapsed)")
            Button("Take Notes…") {
                NSApplication.shared.activate()
                openWindow(id: SceneID.mainWindow)
                LibraryStore.shared.showRecording()
            }
        } else if controller.phase == .saving {
            Text("Saving…")
        }

        if controller.lastSavedFolder != nil {
            Button("Reveal Last Recording") {
                controller.revealLastSaved()
            }
        }

        Divider()

        Button("Open Minutes") {
            NSApplication.shared.activate()
            openWindow(id: SceneID.mainWindow)
        }

        Button("Settings…") {
            NSApplication.shared.activate()
            openSettings()
        }

        Divider()

        Button("Quit Minutes") {
            NSApplication.shared.terminate(nil)
        }
    }
}

/// The status item. It stays alive for the whole run, unlike the window or the menu, so it
/// also opens Settings when the recorder asks, since only views can do that.
struct MenuBarLabel: View {
    @Environment(\.openSettings) private var openSettings
    private let controller = RecordingController.shared

    private static let recordingImage: NSImage = {
        let configuration = NSImage.SymbolConfiguration(hierarchicalColor: .systemRed)
        let symbol = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
        let image = symbol?.withSymbolConfiguration(configuration) ?? NSImage()
        // SwiftUI would otherwise tint this like every other menu bar icon, and lose the red.
        image.isTemplate = false
        return image
    }()

    var body: some View {
        Group {
            if controller.isRecording {
                Image(nsImage: Self.recordingImage)
                    .accessibilityLabel("Minutes, recording")
            } else {
                // Without this label VoiceOver reads the symbol's name, "Audio Waveform".
                Image(systemName: "waveform")
                    .accessibilityLabel("Minutes")
            }
        }
        .onChange(of: controller.settingsRequests) {
            NSApplication.shared.activate()
            openSettings()
        }
    }
}
