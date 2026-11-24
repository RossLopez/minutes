// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        GlobalHotKey.shared.onPress = {
            RecordingController.shared.toggle()
        }
        GlobalHotKey.shared.register(HotKeyShortcut.load())
        UpdateCenter.shared.start()
        AppearancePreference.saved.apply()
        #if DEBUG
            // After the saved appearance, so screenshots look the same whatever it is.
            ScreenshotMode.apply()
        #endif

        Task {
            await LibraryStore.shared.refresh()
            await RecordingController.shared.recoverUnfinishedMeetings()
            TranscriptionCenter.shared.queue.resumeInterrupted(in: LibraryStore.shared.library)
            SummaryCenter.shared.updateHold()
            SummaryCenter.shared.queue.resumeInterrupted(in: LibraryStore.shared.library)
            await SpeakerCenter.shared.refresh()
            await ChatCenter.shared.refresh()
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        RecordingController.shared.handleTerminationRequest()
    }

    func applicationWillTerminate(_: Notification) {
        NotesCenter.shared.prepareForExit()
        SummaryCenter.shared.prepareForExit()
        SearchCenter.shared.prepareForExit()
    }

    /// A recording must keep going after the main window closes, and the menu bar item must stay available.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
