// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        GlobalHotKey.shared.onPress = {
            RecordingController.shared.toggle()
        }
        GlobalHotKey.shared.register(HotKeyShortcut.load())

        Task {
            await LibraryStore.shared.refresh()
            await RecordingController.shared.recoverUnfinishedMeetings()
            TranscriptionCenter.shared.queue.resumeInterrupted(in: LibraryStore.shared.library)
            await SpeakerCenter.shared.refresh()
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        RecordingController.shared.handleTerminationRequest()
    }

    /// A recording must keep going after the main window closes, and the menu bar item must stay available.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
