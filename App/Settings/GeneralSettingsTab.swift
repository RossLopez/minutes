// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

struct GeneralSettingsTab: View {
    @State private var shortcut = HotKeyShortcut.load()
    @State private var isCapturing = false
    @State private var monitor: Any?
    @State private var failedShortcut: String?

    var body: some View {
        Form {
            LabeledContent("Start or stop recording") {
                HStack {
                    Button(isCapturing ? "Type a shortcut…" : shortcut.display) {
                        isCapturing ? stopCapturing() : startCapturing()
                    }
                    .accessibilityHint("Press to set a new global shortcut")
                    if shortcut != .default {
                        Button("Reset") {
                            apply(.default)
                        }
                    }
                }
            }
            if let failedShortcut {
                Text("\(failedShortcut) isn't available. Another app may be using it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: stopCapturing)
    }

    private func startCapturing() {
        isCapturing = true
        failedShortcut = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopCapturing()
                return nil
            }
            guard let new = HotKeyShortcut(event: event) else {
                NSSound.beep()
                return nil
            }
            apply(new)
            stopCapturing()
            return nil
        }
    }

    private func stopCapturing() {
        isCapturing = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func apply(_ new: HotKeyShortcut) {
        if GlobalHotKey.shared.register(new) {
            new.save()
            shortcut = new
            failedShortcut = nil
        } else {
            failedShortcut = new.display
            // Registering removed the old shortcut first, so put it back.
            GlobalHotKey.shared.register(shortcut)
        }
    }
}
